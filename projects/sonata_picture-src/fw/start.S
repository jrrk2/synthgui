# Reset entry of the picture program. The boot ROM is at 0x00000000 and the VexRiscv cluster starts there, as it does for the
# LiteX BIOS this program replaces; the SRAM (0x10000000, 6 KB) holds the stack.
        .section .text.start, "ax"
        .globl  _start
_start:
        la      sp, _stack_top
        call    main
1:      wfi
        j       1b
