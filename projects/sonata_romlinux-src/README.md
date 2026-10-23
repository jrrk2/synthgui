# sonata_romlinux

The VC707 "LiteX Linux from ROM" SoC (`vc707_romlinux`) retargeted to the lowRISC Sonata board, with the ROM
and the RAM outside the FPGA:

| Region | Address | What |
|---|---|---|
| boot ROM | `0x00000000` | 64 KB block RAM holding the LiteX BIOS (34 KB used) |
| SRAM | `0x10000000` | 6 KB block RAM |
| main RAM | `0x40000000` | 8 MB W956 HyperRAM, LiteX's 4:1 SDR HyperRAM core |
| SPI flash | `0x02000000` | W25Q256 on the appspi pins, quad read in place (`READ_1_1_4`, 24-bit address: the low 16 MB) |
| CSRs | `0xF0000000` | UART (C17/D18), timer, flash master, `hr_id0/hr_id1/hr_cr0/hr_ok` |

CPU: VexRiscv-SMP Linux variant, one core, 4 KB caches, 50 MHz, with compressed instructions (`--with-rvc`,
cluster `Cc1_Iw32Is4096Iy1_Dw32Ds4096Dy1_ITs4DTs4_Ood_Wm_Rvc`, generated with sbt/SpinalHDL by LiteX). The userland
in the flash rootfs is built with compressed instructions, so the CPU needs them. There is no PMP.
The system clock is 50 MHz because the sonata-linux device tree, kernel and flash image
(`github.com/jrrk2/sonata-linux`) assume a 50 MHz timebase; the HyperRAM clock is therefore 12.5 MHz.

## What differs from sonata-linux's Vivado target

* HyperRAM `clk_ratio="4:1"` (fabric flops and tri-states) instead of `"2:1"` (ODDR/IDDR, 2x clock).
  Variable latency 4, CR0 `0x8FF7`, written by a small FSM (`HyperRAMInit`) before the first access; see
  `projects/sonata-lib/README.md`.
* `HyperRAMGuard` between the bus and the core: a transaction is at most 16 words and the next one waits for
  chip select to rise, so the device's 4 us tCSM is never exceeded and adjacent requests never merge.
* SPI flash: the plain 24-bit quad read (the pinned litespi's W25Q256JVM has no 4-byte read opcode);
  `SDRInput` is lowered to a flop instead of an IDDR.
* No SD card, SPI Ethernet or JTAG TAP.
* Caches are the 4 KB prebuilt cluster, not 64 KB.

## Regenerating

`gen_soc.py` needs migen, litex, litespi (4c04564) and pythondata-cpu-vexriscv-smp; see its docstring.
`gen_soc.v`, the `*.init` files and the VexRiscv cluster here are its output.

    gen_soc.py --cpu-type vexriscv_smp --cpu-variant linux --cpu-count 1 --hardware-breakpoints 0 \
        --with-rvc --with-wishbone-memory --integrated-rom-size 0x10000 --integrated-sram-size 0x1800 \
        --no-compile-gateware --output-dir out

## Booting

The BIOS tries, in order: serial (SFL), flash, ROM, **kernel in flash**, then **TFTP over the KSZ8851**.

* **Standalone:** `kernel.bin` (4 KB M-mode stub + RAM kernel Image) in flash at `0x02000000` is copied to RAM at
  `0x40200000` and entered; the stub moves the Image to `0x40000000` and drops to S-mode. Linux mounts the romfs in
  the flash `rootfs` partition (`0x5C0000`) and starts `/sbin/init`, a shell script (busybox has no `init` applet).
  Boot takes about 40 s, no network needed. Press Q or ESC at the countdown for the BIOS prompt.
* **Network:** `tftpboot` (or `tftpget <file> <addr>`, then `boot`/`flash_write`). The 8 DIP switches select the TFTP
  server: `0x00` is the built-in address (192.168.1.106, `--remote-ip`), any other value is the last octet on the same
  subnet. The switches are active low (ON = 0 on the pins), the BIOS inverts them. `linux/tools/tftpd.py` is a minimal
  TFTP server (port 69; macOS lets a normal user bind it).
* **Flashing:** `make -C linux flash` prints the BIOS commands. `flash_write` does not erase: run `flash_erase_range`
  first. `mem_cmp` counts words, not bytes.

## Linux images (`linux/`)

`linux/images/` holds the built binaries: `stub.bin`, `kernel.bin`, `sonata-ram.dtb`, `rootfs.romfs`. `linux/Makefile`
rebuilds all of them from source (kernel `jrrk2/linux` at `af93851f1ec4d62f7f8c91b5399849c604c19144` with the patches
in `linux/kernel/`, the stub in `stub.S`, the rootfs from `rootfs-base.romfs` plus `tools/romfs_add.py`); that is the
corresponding source for the GPL components. The kernel builds on macOS with the host shims in `linux/kernel/hostinc`
and `ld.lld`.

## Lessons from bring-up

* The stock stub writes PMP CSRs; this VexRiscv has none, so they trap and the CPU restarts the BIOS. `build_stub.sh
  -DNO_PMP` turns them into nops (the BIOS also patches them after a TFTP download).
* An XIP kernel from flash (and OpenSBI with `FW_RW_ADDR`) does not work here. Instruction fetch from the flash is fine
  (a 12 KB loop ran 6000 times without error), but the XIP kernel hangs early; QEMU's Sonata machine boots it, so the
  cause is VexRiscv-specific and not understood. OpenSBI with `FW_RW_ADDR=0x407F8000` overruns the 8 MB RAM
  (stacks for 2 harts + heap), which QEMU reproduces. The RAM kernel copied from flash is the supported route.
* The Verilator-based mapper dropped a true-dual-port RAM and a flop with an async reset feeding back on itself,
  silently; `rtl/spi_buf_ram.sv` and `spi_wb.sv` are written to avoid both.
