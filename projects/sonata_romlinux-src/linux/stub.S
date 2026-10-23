/*
 * Minimal M-mode stub for LiteX VexRiscv SMP on Sonata FPGA
 *
 * Replaces OpenSBI (260KB) with ~2KB.  The init code runs once from
 * HyperRAM, copies the trap handler to SRAM (0x10000000, invisible to
 * Linux), sets up PMP/delegation, then mrets into S-mode.
 *
 * SMP support: hart 0 boots the kernel; hart 1 is parked in SRAM
 * until Linux calls SBI HSM hart_start().
 *
 * The resident trap handler in SRAM handles:
 *   - SBI ecalls from S-mode (timer, base, HSM, IPI extensions)
 *   - M-mode timer interrupts (injects STIP)
 *   - M-mode software interrupts (injects SSIP for IPI)
 *   - Illegal instruction (emulates rdtime/rdtimeh, forwards others)
 */

/* ── Constants ─────────────────────────────────────────────────────── */

.equ SRAM_BASE,         0x10000000

/*
 * SRAM layout (6KB = 0x10000000 - 0x100017FF):
 *   0x10000000 - 0x100007FF: trap handler code (2KB)
 *   0x10000800 - 0x1000083F: shared SMP data (64 bytes)
 *   0x10000C00:              hart 0 mscratch (stack grows down, 128B frame)
 *   0x10001400:              hart 1 mscratch (stack grows down, 128B frame)
 */
.equ SRAM_SHARED,       0x10000800
.equ SRAM_STACK_H0,     0x10000C00
.equ SRAM_STACK_H1,     0x10001400

/*
 * Shared data layout at SRAM_SHARED:
 *   +0x00: hart 0 HSM state     (4 bytes)
 *   +0x04: hart 1 HSM state     (4 bytes)
 *   +0x08: hart 1 start_addr    (4 bytes)
 *   +0x0C: hart 1 opaque (a1)   (4 bytes)
 *   +0x10: init_done flag        (4 bytes) — set by hart 0 after init
 */
.equ SHARED_H0_STATE,   0x00
.equ SHARED_H1_STATE,   0x04
.equ SHARED_H1_ENTRY,   0x08
.equ SHARED_H1_OPAQUE,  0x0C
.equ SHARED_INIT_DONE,  0x10

/* HSM states */
.equ HSM_STARTED,       0
.equ HSM_STOPPED,       1
.equ HSM_START_PENDING, 2

.equ CLINT_BASE,        0xf0010000
.equ CLINT_MSIP_BASE,   0xf0010000    /* msip[hart] at base + hart*4 */
.equ CLINT_MTIMECMP,    0xf0014000    /* mtimecmp[hart] at base + hart*8 */
.equ CLINT_MTIME,       0xf001BFF8

/*
 * Boot entry addresses:
 *   HyperRAM:  0x40000000 — kernel loaded by BIOS from SD card
 *   Flash A:   0x02001000 — XIP kernel slot A (stub occupies first 4K)
 *   Flash B:   0x02401000 — XIP kernel slot B (stub occupies first 4K)
 *   rootfs:    0x02800000 — shared romfs in flash
 *
 * Flash layout per slot: [4K M-mode stub | xipImage]
 * The stub is prepended to the kernel image so the combined binary
 * can be written to flash as a single file.  The BIOS (or direct
 * flash boot) enters at the start of the stub, which sets up M-mode
 * and mrets into the kernel at +0x1000.
 *
 * Boot selection via SELSW DIP switches (active-low, active = pressed):
 *   No switch pressed (default): boot from HyperRAM 0x40000000 (SD card)
 *   SELSW[0] pressed:            XIP flash slot A (0x02001000)
 *   SELSW[1] pressed:            XIP flash slot B (0x02401000)
 *
 * Switches are read from LiteX GPIOIn CSR at SWITCHES_IN.
 */
.equ FLASH_BASE,        0x02000000
.equ RAM_ENTRY,         0x40000000
.equ SLOT_A_ENTRY,      0x02001000  /* flash base + 4K stub */
.equ SLOT_B_ENTRY,      0x02401000  /* flash base + 4K stub */

.equ SWITCHES_IN,       0xf0004800    /* LiteX GPIOIn CSR (3-bit, active-low) */

.equ UART_BASE,         0xf0001000
.equ UART_RXTX,         0x00
.equ UART_TXFULL,       0x04

.equ SBI_EXT_0_1_SET_TIMER, 0x0
.equ SBI_EXT_BASE,          0x10
.equ SBI_EXT_TIME,          0x54494D45
.equ SBI_EXT_HSM,           0x48534D
.equ SBI_EXT_IPI,           0x735049

.equ SBI_BASE_GET_SPEC_VERSION, 0
.equ SBI_BASE_GET_IMP_ID,       1
.equ SBI_BASE_GET_IMP_VERSION,  2
.equ SBI_BASE_PROBE_EXT,        3
.equ SBI_BASE_GET_MVENDORID,    4
.equ SBI_BASE_GET_MARCHID,      5
.equ SBI_BASE_GET_MIMPID,       6

.equ SBI_HSM_HART_START,      0
.equ SBI_HSM_HART_STOP,       1
.equ SBI_HSM_HART_GET_STATUS, 2

.equ SBI_SUCCESS,           0
.equ SBI_ERR_NOT_SUPPORTED, -2
.equ SBI_ERR_INVALID_PARAM, -3
.equ SBI_ERR_ALREADY_AVAILABLE, -6

.equ MCAUSE_ILLEGAL_INSN,  2
.equ MCAUSE_S_ECALL,       9
.equ MCAUSE_M_SWIRQ,       0x80000003
.equ MCAUSE_M_TIMER_IRQ,   0x80000007

.equ MSTATUS_MPP_S,        0x800
.equ MSTATUS_MIE,          0x8
.equ MIE_MSIE,             0x8
.equ MIE_MTIE,             0x80
.equ MIP_SSIP,             0x2
.equ MIP_STIP,             0x20

/*
 * Trap frame layout: 128 bytes, indexed by register number.
 * offset = regnum * 4.  Slots 0 (x0) and 8 (x2/sp) unused.
 */
.equ FRAME_SIZE, 128

/* ══════════════════════════════════════════════════════════════════════
 * INIT CODE (runs once from load address in HyperRAM)
 * ══════════════════════════════════════════════════════════════════════ */

    .section .text
    .globl _start
    .option norelax

_start:
    /* ── SMP: dispatch based on hart ID ─────────────────────────────── */
    csrr    t0, mhartid
    bnez    t0, .secondary_init

    /* ═══════════════ HART 0: PRIMARY BOOT ═══════════════════════════ */

    /* 1. Copy trap handler to SRAM */
    /* source = _trap_handler (PC-relative, no GOT) */
.La_th:
    auipc   t0, %pcrel_hi(_trap_handler)
    addi    t0, t0, %pcrel_lo(.La_th)
    li      t1, SRAM_BASE           /* destination */
    /* source end = _trap_handler_end (PC-relative) */
.La_the:
    auipc   t2, %pcrel_hi(_trap_handler_end)
    addi    t2, t2, %pcrel_lo(.La_the)

.copy_loop:
    lw      t3, 0(t0)
    sw      t3, 0(t1)
    addi    t0, t0, 4
    addi    t1, t1, 4
    blt     t0, t2, .copy_loop

    /* Ensure I-cache sees the new code */
    fence.i

    /* 2. Initialize shared SMP data in SRAM */
    li      t0, SRAM_SHARED
    li      t1, HSM_STARTED
    sw      t1, SHARED_H0_STATE(t0)   /* hart 0 = STARTED */
    li      t1, HSM_STOPPED
    sw      t1, SHARED_H1_STATE(t0)   /* hart 1 = STOPPED */
    sw      zero, SHARED_H1_ENTRY(t0)
    sw      zero, SHARED_H1_OPAQUE(t0)
    li      t1, 1
    sw      t1, SHARED_INIT_DONE(t0)  /* signal to hart 1 */
    fence                              /* ensure visible */

    /* 3. mtvec = SRAM trap handler */
    li      t0, SRAM_BASE
    csrw    mtvec, t0

    /* 4. mscratch = hart 0 trap stack */
    li      t0, SRAM_STACK_H0
    csrw    mscratch, t0

    /* 5. PMP: SRAM M-only, everything else open */
#ifndef NO_PMP   /* the VexRiscv SMP in this SoC has no PMP: these CSR writes raise illegal-instruction */
    li      t0, 0x040003FF
    csrw    pmpaddr0, t0
    li      t0, 0x3FFFFFFF
    csrw    pmpaddr1, t0
    li      t0, 0x1F18
    csrw    pmpcfg0, t0
#else
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
#endif

    /* 6. Delegate traps — keep illegal insn (bit 2) and ecall-from-S (bit 9) */
    li      t0, 0xFFFFFDFB          /* all except bits 2 and 9 */
    csrw    medeleg, t0
    li      t0, 0xFFFFFFFF
    csrw    mideleg, t0

    /* 7. Enable M-mode timer + software interrupts */
    li      t0, (MIE_MTIE | MIE_MSIE)
    csrw    mie, t0

    /* 8. mstatus.MPP = Supervisor */
    csrr    t0, mstatus
    li      t1, 0x1800
    not     t1, t1
    and     t0, t0, t1
    li      t1, MSTATUS_MPP_S
    or      t0, t0, t1
    csrw    mstatus, t0

    li      s0, UART_BASE

#ifdef TFTP_BOOT
    /* ── TFTP boot: kernel is right after the 4KB stub ──────────── */
    /* Compute kernel entry = our load address + 0x1000 (PC-relative) */
1:  auipc   s4, %pcrel_hi(_start)
    addi    s4, s4, %pcrel_lo(1b)
    li      t0, 0x1000
    add     s4, s4, t0                    /* s4 = kernel at stub + 4KB */

    /* Print "TFTP\n" */
    li      a0, 'T'
    jal     ra, .uart_putc
    li      a0, 'F'
    jal     ra, .uart_putc
    li      a0, 'T'
    jal     ra, .uart_putc
    li      a0, 'P'
    jal     ra, .uart_putc
    li      a0, '\n'
    jal     ra, .uart_putc

    /* Print first 16 bytes of kernel as hex */
    li      a0, 'K'
    jal     ra, .uart_putc
    li      a0, ':'
    jal     ra, .uart_putc
    mv      s1, s4
    li      s2, 16
.print_kern_bytes:
    lbu     a0, 0(s1)
    jal     ra, .uart_puthex8
    li      a0, ' '
    jal     ra, .uart_putc
    addi    s1, s1, 1
    addi    s2, s2, -1
    bnez    s2, .print_kern_bytes
    li      a0, '\n'
    jal     ra, .uart_putc

    /* Fall through to SRAM copier (shared with XIP path) */

#else
    /* ── A/B boot selection via SELSW switches ────────────────────── */

    /* Read switches CSR (active-low: 0 = pressed) */
    li      t0, SWITCHES_IN
    lw      s3, 0(t0)                /* s3 = raw switch value */
    not     s3, s3                   /* invert: 1 = pressed */
    andi    s3, s3, 0x3              /* mask to SELSW[1:0] */

    /* Select kernel entry point:
     *   default (0x0): HyperRAM 0x40000000 (SD card boot)
     *   SELSW[0] (0x1): XIP flash slot A
     *   SELSW[1] (0x2): XIP flash slot B */
    li      s4, RAM_ENTRY             /* s4 = kernel entry (default: HyperRAM) */
    beqz    s3, .boot_slot_selected   /* no switch → SD/RAM boot */
    li      s4, SLOT_A_ENTRY          /* SELSW[0] → slot A */
    andi    t0, s3, 0x2               /* SELSW[1] pressed? */
    beqz    t0, .boot_slot_selected
    li      s4, SLOT_B_ENTRY          /* SELSW[1] → slot B */

.boot_slot_selected:
    /* ── Debug: print boot slot and flash checksums via UART ──────── */
    /* Print banner "STUB:A" or "STUB:B" */
    li      a0, 'S'
    jal     ra, .uart_putc
    li      a0, 'T'
    jal     ra, .uart_putc
    li      a0, 'U'
    jal     ra, .uart_putc
    li      a0, 'B'
    jal     ra, .uart_putc
    li      a0, ':'
    jal     ra, .uart_putc
    /* Print slot letter: R=RAM, A=flash-A, B=flash-B */
    bnez    s3, .print_flash_slot
    li      a0, 'R'
    j       .print_slot_done
.print_flash_slot:
    andi    t0, s3, 0x2
    beqz    t0, .print_a
    li      a0, 'B'
    j       .print_slot_done
.print_a:
    li      a0, 'A'
.print_slot_done:
    jal     ra, .uart_putc
    li      a0, '\n'
    jal     ra, .uart_putc

    /* Print first 16 bytes of selected kernel slot as hex */
    li      a0, 'F'
    jal     ra, .uart_putc
    li      a0, '0'
    jal     ra, .uart_putc
    li      a0, ':'
    jal     ra, .uart_putc
    mv      s1, s4                    /* s4 = selected entry */
    li      s2, 16
.print_flash_bytes:
    lbu     a0, 0(s1)
    jal     ra, .uart_puthex8
    li      a0, ' '
    jal     ra, .uart_putc
    addi    s1, s1, 1
    addi    s2, s2, -1
    bnez    s2, .print_flash_bytes
    li      a0, '\n'
    jal     ra, .uart_putc

    /* Checksum of first 1MB of selected kernel slot */
    li      a0, 'C'
    jal     ra, .uart_putc
    li      a0, '1'
    jal     ra, .uart_putc
    li      a0, ':'
    jal     ra, .uart_putc
    mv      a0, s4                    /* start of selected slot */
    li      a1, 0x100000              /* 1MB length */
    jal     ra, .checksum
    mv      a0, s1                    /* result in s1 */
    jal     ra, .uart_puthex32
    li      a0, '\n'
    jal     ra, .uart_putc

    /* Checksum of rootfs region (512KB at offset 0x800000) */
    li      a0, 'C'
    jal     ra, .uart_putc
    li      a0, '2'
    jal     ra, .uart_putc
    li      a0, ':'
    jal     ra, .uart_putc
    li      a0, (FLASH_BASE + 0x800000)  /* rootfs start */
    li      a1, 0x80000               /* 512KB length */
    jal     ra, .checksum
    mv      a0, s1
    jal     ra, .uart_puthex32
    li      a0, '\n'
    jal     ra, .uart_putc

#endif /* TFTP_BOOT */

    /* ── Continue boot (both TFTP and XIP paths) ─────────────────────── */

    /* 9. Copy kernel to PHYS_RAM_BASE via SRAM copier */
    /* t2 = src, t3 = dst, t4 = dst_end */
    mv      t2, s4                        /* src = kernel at load + 4KB */
    li      t3, 0x40000000                /* dst = PHYS_RAM_BASE */
    lw      t4, 16(s4)                    /* image_size from Image header */
    /* Cap copy size at available RAM (src to end of 8MB HyperRAM) */
    li      t5, 0x40800000
    sub     t5, t5, s4                    /* max = RAM_END - src */
    blt     t4, t5, 1f
    mv      t4, t5                        /* clamp to max */
1:  add     t4, t3, t4                    /* dst_end = dst + size */

    /* mepc = PHYS_RAM_BASE (kernel entry after copy) */
    csrw    mepc, t3

    /* a0 = hartid, a1 = DTB (0 = use built-in DTB) */
    li      a0, 0
    li      a1, 0

    /* Jump to copier in SRAM */
.La_sc:
    auipc   t0, %pcrel_hi(.sram_copier)
    addi    t0, t0, %pcrel_lo(.La_sc)
.La_th2:
    auipc   t1, %pcrel_hi(_trap_handler)
    addi    t1, t1, %pcrel_lo(.La_th2)
    sub     t0, t0, t1                    /* offset within trap handler */
    li      t1, SRAM_BASE
    add     t0, t1, t0                    /* SRAM address of copier */
    jr      t0

    /* ═══════════════ HART 1+: SECONDARY INIT ════════════════════════ */

.secondary_init:
    /* Wait for hart 0 to finish copying trap handler + shared data */
    li      t1, SRAM_SHARED
.wait_init:
    lw      t2, SHARED_INIT_DONE(t1)
    beqz    t2, .wait_init
    fence                              /* acquire barrier */

    /* mtvec = SRAM trap handler */
    li      t0, SRAM_BASE
    csrw    mtvec, t0

    /* mscratch = hart 1 trap stack */
    li      t0, SRAM_STACK_H1
    csrw    mscratch, t0

    /* PMP: same as hart 0 */
#ifndef NO_PMP   /* the VexRiscv SMP in this SoC has no PMP: these CSR writes raise illegal-instruction */
    li      t0, 0x040003FF
    csrw    pmpaddr0, t0
    li      t0, 0x3FFFFFFF
    csrw    pmpaddr1, t0
    li      t0, 0x1F18
    csrw    pmpcfg0, t0
#else
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
#endif

    /* Delegate traps — same as hart 0 */
    li      t0, 0xFFFFFDFB
    csrw    medeleg, t0
    li      t0, 0xFFFFFFFF
    csrw    mideleg, t0

    /* Enable M-mode timer + software interrupts */
    li      t0, (MIE_MTIE | MIE_MSIE)
    csrw    mie, t0

    /* mstatus: MPP = Supervisor, MIE = 1 (enable interrupts for WFI) */
    csrr    t0, mstatus
    li      t1, 0x1800
    not     t1, t1
    and     t0, t0, t1
    li      t1, (MSTATUS_MPP_S | MSTATUS_MIE)
    or      t0, t0, t1
    csrw    mstatus, t0

    /* Clear any pending software interrupt for this hart */
    csrr    t0, mhartid
    slli    t0, t0, 2
    li      t1, CLINT_MSIP_BASE
    add     t0, t1, t0
    sw      zero, 0(t0)

    /* Jump to parking loop in SRAM (safe from HyperRAM overwrites) */
.La_sp:
    auipc   t0, %pcrel_hi(.secondary_park)
    addi    t0, t0, %pcrel_lo(.La_sp)
.La_th3:
    auipc   t1, %pcrel_hi(_trap_handler)
    addi    t1, t1, %pcrel_lo(.La_th3)
    sub     t0, t0, t1              /* offset within handler */
    li      t1, SRAM_BASE
    add     t0, t1, t0             /* SRAM address of parking loop */
    jr      t0

/* ── UART helper routines (used during init only) ─────────────────── */

/* Print character in a0 to UART. Clobbers t0. */
.uart_putc:
1:  lw      t0, UART_TXFULL(s0)
    bnez    t0, 1b
    sw      a0, UART_RXTX(s0)
    ret

/* Print byte in a0 as 2 hex digits. Clobbers a0, t0, t1, t2. */
.uart_puthex8:
    mv      t2, ra
    mv      t1, a0
    srli    a0, t1, 4
    andi    a0, a0, 0xF
    jal     ra, .uart_putnib
    andi    a0, t1, 0xF
    jal     ra, .uart_putnib
    mv      ra, t2
    ret

/* Print 32-bit word in a0 as 8 hex digits. Clobbers a0, t0-t5. */
.uart_puthex32:
    mv      t5, ra
    mv      t4, a0
    srli    a0, t4, 24
    andi    a0, a0, 0xFF
    jal     ra, .uart_puthex8
    srli    a0, t4, 16
    andi    a0, a0, 0xFF
    jal     ra, .uart_puthex8
    srli    a0, t4, 8
    andi    a0, a0, 0xFF
    jal     ra, .uart_puthex8
    andi    a0, t4, 0xFF
    jal     ra, .uart_puthex8
    mv      ra, t5
    ret

/* Print nibble in a0 (0-15) as hex char. Clobbers a0, t0. */
.uart_putnib:
    andi    a0, a0, 0xF
    li      t0, 10
    blt     a0, t0, 1f
    addi    a0, a0, ('a' - 10)
    j       2f
1:  addi    a0, a0, '0'
2:  j       .uart_putc              /* tail call */

/* Simple additive checksum: sum all bytes. a0=start, a1=length.
 * Returns result in s1. Clobbers a0, a1, t0. */
.checksum:
    li      s1, 0
    add     a1, a0, a1              /* a1 = end address */
1:  lbu     t0, 0(a0)
    add     s1, s1, t0
    addi    a0, a0, 1
    blt     a0, a1, 1b
    ret


/* ══════════════════════════════════════════════════════════════════════
 * TRAP HANDLER (copied to SRAM at 0x10000000)
 *
 * Frame: 128 bytes, slot[N] = register xN (offset = N*4).
 * Common path saves only the registers it clobbers.
 * Illegal-instruction path saves all for arbitrary rd writeback.
 * ══════════════════════════════════════════════════════════════════════ */

    .balign 4
_trap_handler:
    csrrw   sp, mscratch, sp
    addi    sp, sp, -FRAME_SIZE

    /* Minimal save (registers used by all paths) */
    sw      ra,   4(sp)             /* x1  */
    sw      t0,  20(sp)             /* x5  */
    sw      t1,  24(sp)             /* x6  */
    sw      t2,  28(sp)             /* x7  */
    sw      t3, 112(sp)             /* x28 */
    sw      t4, 116(sp)             /* x29 */
    sw      t5, 120(sp)             /* x30 */
    sw      a0,  40(sp)             /* x10 */
    sw      a1,  44(sp)             /* x11 */
    sw      a2,  48(sp)             /* x12 — needed by HSM */
    sw      a6,  64(sp)             /* x16 */
    sw      a7,  68(sp)             /* x17 */

    csrr    t0, mcause

    /* Illegal instruction? */
    li      t1, MCAUSE_ILLEGAL_INSN
    beq     t0, t1, .handle_illegal_insn

    /* Interrupt? */
    bltz    t0, .handle_interrupt

    /* ecall from S-mode? */
    li      t1, MCAUSE_S_ECALL
    bne     t0, t1, .trap_unknown

    /* ── SBI ecall ────────────────────────────────────────────────── */
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0

    li      t0, SBI_EXT_0_1_SET_TIMER
    beq     a7, t0, .sbi_set_timer

    li      t0, SBI_EXT_TIME
    beq     a7, t0, .sbi_set_timer_v02

    li      t0, SBI_EXT_BASE
    beq     a7, t0, .sbi_base

    li      t0, SBI_EXT_HSM
    beq     a7, t0, .sbi_hsm

    li      t0, SBI_EXT_IPI
    beq     a7, t0, .sbi_ipi

    li      a0, SBI_ERR_NOT_SUPPORTED
    li      a1, 0
    j       .trap_ret_ecall

    /* ── SBI set_timer (per-hart) ────────────────────────────────── */
.sbi_set_timer:
    /* Compute per-hart MTIMECMP: base + mhartid * 8 */
    csrr    t0, mhartid
    slli    t0, t0, 3
    li      t1, CLINT_MTIMECMP
    add     t0, t1, t0
    sw      a0, 0(t0)
    sw      a1, 4(t0)
    li      t0, MIP_STIP
    csrc    mip, t0
    li      t0, MIE_MTIE
    csrs    mie, t0
    li      a0, 0
    j       .trap_ret_ecall

.sbi_set_timer_v02:
    /* Compute per-hart MTIMECMP: base + mhartid * 8 */
    csrr    t0, mhartid
    slli    t0, t0, 3
    li      t1, CLINT_MTIMECMP
    add     t0, t1, t0
    sw      a0, 0(t0)
    sw      a1, 4(t0)
    li      t0, MIP_STIP
    csrc    mip, t0
    li      t0, MIE_MTIE
    csrs    mie, t0
    li      a0, SBI_SUCCESS
    li      a1, 0
    j       .trap_ret_ecall

    /* ── SBI BASE extension ──────────────────────────────────────── */
.sbi_base:
    li      t0, SBI_BASE_GET_SPEC_VERSION
    beq     a6, t0, .base_spec
    li      t0, SBI_BASE_GET_IMP_ID
    beq     a6, t0, .base_imp_id
    li      t0, SBI_BASE_GET_IMP_VERSION
    beq     a6, t0, .base_imp_ver
    li      t0, SBI_BASE_PROBE_EXT
    beq     a6, t0, .base_probe
    li      t0, SBI_BASE_GET_MVENDORID
    beq     a6, t0, .base_zero
    li      t0, SBI_BASE_GET_MARCHID
    beq     a6, t0, .base_zero
    li      t0, SBI_BASE_GET_MIMPID
    beq     a6, t0, .base_zero
    li      a0, SBI_ERR_NOT_SUPPORTED
    li      a1, 0
    j       .trap_ret_ecall

.base_spec:
    li      a0, SBI_SUCCESS
    li      a1, 2                   /* SBI spec v0.2 */
    j       .trap_ret_ecall

.base_imp_id:
    li      a0, SBI_SUCCESS
    li      a1, 0xFF                /* custom implementation */
    j       .trap_ret_ecall

.base_imp_ver:
    li      a0, SBI_SUCCESS
    li      a1, 2                   /* version 2: SMP support */
    j       .trap_ret_ecall

.base_probe:
    li      a1, 0
    li      t0, SBI_EXT_TIME
    beq     a0, t0, .probe_yes
    li      t0, SBI_EXT_BASE
    beq     a0, t0, .probe_yes
    li      t0, SBI_EXT_0_1_SET_TIMER
    beq     a0, t0, .probe_yes
    li      t0, SBI_EXT_HSM
    beq     a0, t0, .probe_yes
    li      t0, SBI_EXT_IPI
    beq     a0, t0, .probe_yes
    li      a0, SBI_SUCCESS
    j       .trap_ret_ecall

.probe_yes:
    li      a0, SBI_SUCCESS
    li      a1, 1
    j       .trap_ret_ecall

.base_zero:
    li      a0, SBI_SUCCESS
    li      a1, 0
    j       .trap_ret_ecall

    /* ── SBI HSM extension ───────────────────────────────────────── */
.sbi_hsm:
    li      t0, SBI_HSM_HART_START
    beq     a6, t0, .hsm_hart_start
    li      t0, SBI_HSM_HART_GET_STATUS
    beq     a6, t0, .hsm_hart_status
    li      t0, SBI_HSM_HART_STOP
    beq     a6, t0, .hsm_hart_stop
    li      a0, SBI_ERR_NOT_SUPPORTED
    li      a1, 0
    j       .trap_ret_ecall

.hsm_hart_start:
    /* a0 = hartid, a1 = start_addr, a2 = opaque */
    /* Only support hartid 1 */
    li      t0, 1
    bne     a0, t0, .hsm_invalid_param

    /* Check hart 1 is currently STOPPED */
    li      t0, SRAM_SHARED
    lw      t1, SHARED_H1_STATE(t0)
    li      t2, HSM_STOPPED
    bne     t1, t2, .hsm_already_avail

    /* Store start address and opaque */
    sw      a1, SHARED_H1_ENTRY(t0)
    sw      a2, SHARED_H1_OPAQUE(t0)

    /* Set state to START_PENDING */
    li      t1, HSM_START_PENDING
    sw      t1, SHARED_H1_STATE(t0)
    fence                           /* ensure stores visible */

    /* Send IPI to hart 1 */
    li      t0, CLINT_MSIP_BASE
    li      t1, 1
    sw      t1, 4(t0)              /* msip[1] = 1 */

    li      a0, SBI_SUCCESS
    li      a1, 0
    j       .trap_ret_ecall

.hsm_invalid_param:
    li      a0, SBI_ERR_INVALID_PARAM
    li      a1, 0
    j       .trap_ret_ecall

.hsm_already_avail:
    li      a0, SBI_ERR_ALREADY_AVAILABLE
    li      a1, 0
    j       .trap_ret_ecall

.hsm_hart_status:
    /* a0 = hartid */
    li      t0, 1
    bgt     a0, t0, .hsm_invalid_param
    /* Load state: shared + hartid*4 */
    li      t0, SRAM_SHARED
    slli    t1, a0, 2
    add     t0, t0, t1
    lw      a1, 0(t0)
    li      a0, SBI_SUCCESS
    j       .trap_ret_ecall

.hsm_hart_stop:
    /* Mark calling hart as STOPPED, then spin forever in WFI */
    csrr    t0, mhartid
    slli    t0, t0, 2
    li      t1, SRAM_SHARED
    add     t0, t1, t0
    li      t1, HSM_STOPPED
    sw      t1, 0(t0)
    fence
.hart_stop_loop:
    wfi
    j       .hart_stop_loop

    /* ── SBI IPI extension (sPI) ─────────────────────────────────── */
.sbi_ipi:
    /* a0 = hart_mask, a1 = hart_mask_base
     * For our 2-hart system: check each hart in the mask
     * and write 1 to their MSIP register to inject SSIP. */

    /* Check if hart 0 is in mask: bit (0 - base) of mask */
    bltz    a1, .ipi_check_h1       /* base < 0: hart 0 not in mask */
    sub     t0, zero, a1            /* t0 = -base = bit position for hart 0 */
    srl     t0, a0, t0             /* RV32 uses lower 5 bits of shift */
    andi    t0, t0, 1
    beqz    t0, .ipi_check_h1
    /* Hart 0 in mask: set msip[0] */
    li      t0, CLINT_MSIP_BASE
    li      t1, 1
    sw      t1, 0(t0)

.ipi_check_h1:
    /* Check if hart 1 is in mask: bit (1 - base) of mask */
    li      t0, 1
    sub     t0, t0, a1             /* t0 = 1 - base = bit position */
    bltz    t0, .ipi_done           /* if negative, hart 1 not in mask */
    li      t1, 31
    bgt     t0, t1, .ipi_done      /* if >= 32, not in mask */
    srl     t0, a0, t0
    andi    t0, t0, 1
    beqz    t0, .ipi_done
    /* Hart 1 in mask: set msip[1] */
    li      t0, CLINT_MSIP_BASE
    li      t1, 1
    sw      t1, 4(t0)

.ipi_done:
    li      a0, SBI_SUCCESS
    li      a1, 0
    j       .trap_ret_ecall

    /* ── Interrupt dispatch ──────────────────────────────────────── */
.handle_interrupt:
    li      t1, MCAUSE_M_TIMER_IRQ
    beq     t0, t1, .handle_timer

    li      t1, MCAUSE_M_SWIRQ
    beq     t0, t1, .handle_swirq

    j       .trap_unknown

    /* ── M-mode timer interrupt (per-hart) ───────────────────────── */
.handle_timer:
    /* Compute per-hart MTIMECMP: base + mhartid * 8 */
    csrr    t0, mhartid
    slli    t0, t0, 3
    li      t1, CLINT_MTIMECMP
    add     t0, t1, t0
    li      t1, -1
    sw      t1, 0(t0)
    sw      t1, 4(t0)
    li      t0, MIE_MTIE
    csrc    mie, t0
    li      t0, MIP_STIP
    csrs    mip, t0
    j       .trap_ret_notouch

    /* ── M-mode software interrupt (IPI → inject SSIP) ───────────── */
.handle_swirq:
    /* Clear this hart's MSIP */
    csrr    t0, mhartid
    slli    t0, t0, 2
    li      t1, CLINT_MSIP_BASE
    add     t0, t1, t0
    sw      zero, 0(t0)

    /* Inject S-mode software interrupt (SSIP) */
    li      t0, MIP_SSIP
    csrs    mip, t0

    j       .trap_ret_notouch

    /* ── Illegal instruction ──────────────────────────────────────── */
.handle_illegal_insn:
    /* Save all remaining registers for arbitrary rd writeback */
    sw      gp,  12(sp)
    sw      tp,  16(sp)
    sw      s0,  32(sp)
    sw      s1,  36(sp)
    sw      a3,  52(sp)
    sw      a4,  56(sp)
    sw      a5,  60(sp)
    sw      s2,  72(sp)
    sw      s3,  76(sp)
    sw      s4,  80(sp)
    sw      s5,  84(sp)
    sw      s6,  88(sp)
    sw      s7,  92(sp)
    sw      s8,  96(sp)
    sw      s9, 100(sp)
    sw      s10,104(sp)
    sw      s11,108(sp)
    sw      t6, 124(sp)

    /* Get faulting instruction from mtval (avoids virtual address access) */
    csrr    t2, mtval

    /* Check pattern: CSRRS rd, csr, x0  (funct3=010, rs1=0, opcode=SYSTEM)
     * mask  = 0x000FF07F  (checks rs1, funct3, opcode; ignores CSR and rd)
     * match = 0x00002073 */
    li      t3, 0x000FF07F
    and     t4, t2, t3
    li      t3, 0x2073
    bne     t4, t3, .fwd_to_smode

    /* Extract CSR number (bits 31:20) */
    srli    t4, t2, 20

    li      t3, 0xC01               /* time */
    beq     t4, t3, .emul_rdtime

    li      t3, 0xC81               /* timeh */
    beq     t4, t3, .emul_rdtimeh

    j       .fwd_to_smode

.emul_rdtime:
    li      t3, CLINT_MTIME
    lw      t3, 0(t3)              /* low 32 bits of mtime */
    j       .emul_write_rd

.emul_rdtimeh:
    li      t3, CLINT_MTIME
    lw      t3, 4(t3)              /* high 32 bits of mtime */

.emul_write_rd:
    /* Extract rd = (instruction >> 7) & 0x1F */
    srli    t2, t2, 7
    andi    t2, t2, 0x1F
    beqz    t2, .emul_done          /* x0, nothing to write */

    /* Write value into frame slot: frame[rd*4] = t3 */
    slli    t2, t2, 2
    add     t2, sp, t2
    sw      t3, 0(t2)

.emul_done:
    /* Advance mepc past the faulting instruction */
    csrr    t1, mepc
    addi    t1, t1, 4
    csrw    mepc, t1
    j       .trap_ret_full

    /* ── Forward non-time illegal instruction to S-mode ───────────── */
.fwd_to_smode:
    csrr    t1, mepc
    csrw    sepc, t1

    li      t1, MCAUSE_ILLEGAL_INSN
    csrw    scause, t1

    csrr    t1, mtval
    csrw    stval, t1

    /* mstatus: SPIE ← SIE, SIE ← 0, SPP ← (was S-mode?) */
    csrr    t1, mstatus
    andi    t2, t1, 2               /* SIE (bit 1) */
    slli    t2, t2, 4               /* → SPIE (bit 5) */
    srli    t3, t1, 3               /* shift bit 11 → bit 8 */
    andi    t3, t3, 0x100           /* isolate SPP (bit 8) */
    li      t4, 0x122               /* clear SIE, SPIE, SPP */
    not     t4, t4
    and     t1, t1, t4
    or      t1, t1, t2              /* set SPIE */
    or      t1, t1, t3              /* set SPP */
    csrw    mstatus, t1

    csrr    t1, stvec
    andi    t1, t1, -4              /* clear mode bits */
    csrw    mepc, t1

    j       .trap_ret_full

    /* ── Unknown trap — ignore ────────────────────────────────────── */
.trap_unknown:
    j       .trap_ret_notouch

    /* ── Return paths ─────────────────────────────────────────────── */

    /* ecall return: a0/a1 hold return values, don't restore them */
.trap_ret_ecall:
    lw      ra,   4(sp)
    lw      t0,  20(sp)
    lw      t1,  24(sp)
    lw      t2,  28(sp)
    lw      t3, 112(sp)
    lw      t4, 116(sp)
    lw      t5, 120(sp)
    lw      a2,  48(sp)
    lw      a6,  64(sp)
    lw      a7,  68(sp)
    addi    sp, sp, FRAME_SIZE
    csrrw   sp, mscratch, sp
    mret

    /* No-touch return: restore all minimal-saved registers */
.trap_ret_notouch:
    lw      ra,   4(sp)
    lw      t0,  20(sp)
    lw      t1,  24(sp)
    lw      t2,  28(sp)
    lw      t3, 112(sp)
    lw      t4, 116(sp)
    lw      t5, 120(sp)
    lw      a0,  40(sp)
    lw      a1,  44(sp)
    lw      a2,  48(sp)
    lw      a6,  64(sp)
    lw      a7,  68(sp)
    addi    sp, sp, FRAME_SIZE
    csrrw   sp, mscratch, sp
    mret

    /* Full return: restore ALL registers (used after illegal insn) */
.trap_ret_full:
    lw      ra,   4(sp)
    lw      gp,  12(sp)
    lw      tp,  16(sp)
    lw      t0,  20(sp)
    lw      t1,  24(sp)
    lw      t2,  28(sp)
    lw      s0,  32(sp)
    lw      s1,  36(sp)
    lw      a0,  40(sp)
    lw      a1,  44(sp)
    lw      a2,  48(sp)
    lw      a3,  52(sp)
    lw      a4,  56(sp)
    lw      a5,  60(sp)
    lw      a6,  64(sp)
    lw      a7,  68(sp)
    lw      s2,  72(sp)
    lw      s3,  76(sp)
    lw      s4,  80(sp)
    lw      s5,  84(sp)
    lw      s6,  88(sp)
    lw      s7,  92(sp)
    lw      s8,  96(sp)
    lw      s9, 100(sp)
    lw      s10,104(sp)
    lw      s11,108(sp)
    lw      t3, 112(sp)
    lw      t4, 116(sp)
    lw      t5, 120(sp)
    lw      t6, 124(sp)
    addi    sp, sp, FRAME_SIZE
    csrrw   sp, mscratch, sp
    mret

    /* ── Secondary hart parking loop (runs in SRAM) ──────────────── */
    .balign 4
.secondary_park:
    wfi

    /* Check if HSM state changed to START_PENDING */
    li      t0, SRAM_SHARED
    lw      t1, SHARED_H1_STATE(t0)
    li      t2, HSM_START_PENDING
    bne     t1, t2, .secondary_park

    /* We've been started — mark as STARTED */
    li      t1, HSM_STARTED
    sw      t1, SHARED_H1_STATE(t0)

    /* Load entry point and opaque value */
    lw      t1, SHARED_H1_ENTRY(t0)
    lw      t2, SHARED_H1_OPAQUE(t0)

    /* Clear software interrupt */
    li      t0, CLINT_MSIP_BASE
    sw      zero, 4(t0)            /* clear msip[1] */

    /* Set up for S-mode entry */
    csrw    mepc, t1

    csrr    a0, mhartid             /* a0 = hartid */
    mv      a1, t2                  /* a1 = opaque */

    mret

    /* ── Kernel copier (runs in SRAM, safe from overwrites) ────────── */
    /*
     * Copies kernel from src to dst, then mrets to dst.
     * Entry: t2=src, t3=dst, t4=dst_end
     *        mepc=dst (set by caller), a0=0, a1=0 (set by caller)
     */
    .balign 4
.sram_copier:
    lw      t5, 0(t2)
    sw      t5, 0(t3)
    addi    t2, t2, 4
    addi    t3, t3, 4
    blt     t3, t4, .sram_copier
    fence.i
    fence
    mret

_trap_handler_end:
