# sonata_romlinux

The VC707 "LiteX Linux from ROM" SoC (`vc707_romlinux`) retargeted to the lowRISC Sonata board, with the ROM
and the RAM outside the FPGA:

| Region | Address | What |
|---|---|---|
| boot ROM | `0x00000000` | 64 KB block RAM holding the LiteX BIOS (35 KB used) |
| SRAM | `0x10000000` | 6 KB block RAM |
| main RAM | `0x40000000` | 8 MB W956 HyperRAM, LiteX's 4:1 SDR HyperRAM core |
| SPI flash | `0x02000000` | W25Q256 on the appspi pins, quad read in place (`READ_1_1_4`, 24-bit address: the low 16 MB) |
| KSZ8851 SPI host | `0x80302000` | the SPI Ethernet chip (`spi_wb`, 8 KB window), IRQ 2 |
| LCD text console | `0x80305000` | write-only character RAM of the 160x128 ST7735 panel, scroll register at `+0x140` |
| CSRs | `0xF0000000` | UART (C17/D18), timer, flash master, DIP switches (`dip`), `eth_rst`, `hr_id0/hr_id1/hr_cr0/hr_ok` |
| CLINT / PLIC | `0xF0010000` / `0xF0C00000` | |

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
* No SD card or JTAG TAP. The KSZ8851 SPI Ethernet is there (BIOS TFTP boot, Linux `ks8851`), and so is the LCD.
* Caches are the 4 KB prebuilt cluster, not 64 KB.

## Rebuilding everything

Needs (macOS/Homebrew paths shown; Linux is the same without the `gnubin` PATH): this repository's `build/synthgui`
(the open flow: Verilator mapper, nextpnr-himbaechel, prjxray) and `build-deps/prefix/bin/openFPGALoader`; Python 3.12
with `packaging pyyaml requests pyserial`; LiteX, migen, litespi (4c04564), pythondata-cpu-vexriscv-smp,
pythondata-software-picolibc and -compiler_rt; `riscv64-elf-gcc` with an rv32 multilib; `dtc`, `gmake`; JDK 21 and `sbt`
(only to generate the VexRiscv cluster); for the kernel on macOS also `ld.lld` (`brew install lld`) and GNU coreutils.

1. **SoC (gateware sources and BIOS).** `gen_soc.py` writes `gen_soc.v`, the `*.init` files, the VexRiscv cluster and
   the XDC, and compiles the BIOS from `bios/` (a copy of LiteX's BIOS plus `spieth_boot.c`, the kernel-in-flash boot
   method in `main.c`, `tftpget`). `JAVA_HOME` must point at JDK 21 the first time (sbt generates the cluster).

       L=<litex-deps>
       PYTHONPATH=$L/migen:$L/litex:<litespi>:$L/pythondata-cpu-vexriscv-smp:$L/pythondata-software-picolibc:$L/pythondata-software-compiler_rt:$L/litedram:$L/liteeth \
       python3.12 gen_soc.py --cpu-type vexriscv_smp --cpu-variant linux --cpu-count 1 --hardware-breakpoints 0 \
           --with-rvc --with-wishbone-memory --integrated-rom-size 0x10000 --integrated-sram-size 0x1800 \
           --no-compile-gateware --output-dir out

   Copy `out/gateware/{gen_soc.v,gen_soc_rom.init,gen_soc_sram.init,gen_soc_mem.init}` and the generated
   `VexRiscvLitexSmpCluster_*_Rvc.v` into this directory; `gen_soc.xdc` is `out/gateware/gen_soc.xdc` with
   `create_clock -period 40.000 -name clk25 [get_ports clk25]` on top and `PULLUP` lines changed to
   `set_property PULLTYPE PULLUP`. `--remote-ip`, `--boot-file` and `--load-addr` set the TFTP defaults.
2. **LCD ROMs** (only if `sonata-lib/lcd_*.v` change): `python3 gen_lcd_roms.py` writes `rtl/lcd_font.v`,
   `rtl/lcd_init_rom.v` and the two `.hex` files; they must stay memories (a `case` ROM makes a 20-LUT chain and
   misses 50 MHz).
3. **Bitstream.** From the repository root:

       QT_QPA_PLATFORM=offscreen build/synthgui --project projects/sonata_romlinux.json --run synth,pnr,bit,uf2

   Work files go to `~/synthgui-work/sonata_romlinux/`: `gen_soc.bit` and `gen_soc.bit.slot1.uf2`. Check
   `pnr.log` for `Max frequency ... PASS at 50.00 MHz` (65-70 MHz is normal; the build still produces a
   bitstream if timing fails).
4. **Program.** Volatile, over JTAG: `build-deps/prefix/bin/openFPGALoader -c ft4232 gen_soc.bit`. Non-volatile: copy
   `gen_soc.bit.slot1.uf2` to the `SONATA` USB drive and `sync`; `LOG.TXT` on the drive reports the programming.
5. **Linux images.** `make -C linux` builds `linux/images/{stub.bin,kernel.bin,sonata-ram.dtb,rootfs.romfs}` (see
   below). The committed images are the output of this Makefile.
6. **Flash them.** Serve `linux/images/` over TFTP (`python3 linux/tools/tftpd.py linux/images`, then set the DIP
   switches to the server's last octet), reset, press ESC at the boot countdown, and at the BIOS prompt:

       tftpflash kernel.bin kernel
       tftpflash rootfs.romfs rootfs
       reboot

   `tftpflash <file> <partition>` streams the file into the flash partition of that name; the names and offsets are the
   device tree's MTD table (`linux/kernel/sonata-ram.dts`: `kernel` 0x0, `opensbi` 0x540000, `rootfs` 0x5C0000), so it
   writes where Linux reads. The BIOS's copy of the table, `bios/partitions.h`, is generated from the device tree by
   `linux/tools/dts_partitions.py` (`make -C linux ../bios/partitions.h`) and the BIOS has to be rebuilt after the
   table changes. `tftpflash` with no arguments lists the partitions; a plain offset (a multiple of 0x10000) still works.
   It collects 64 KB, erases that block, writes and verifies it, and goes on, so the file size is limited only by the
   partition (it stops with an error if the file is larger; only the low 16 MB of the flash are addressable) and nothing
   has to fit in the 8 MB of RAM. It prints
   `N bytes written and verified at flash ...` when done. Do not reset while it runs; an interrupted write leaves a
   corrupt partition, recovered by flashing again from the BIOS prompt. `make -C linux flash` prints the commands.
   The TFTP server must tolerate pauses (a block takes a second or so to flash) and ignore duplicate ACKs; the
   included `tools/tftpd.py` does.

## Programming on the board

The rootfs carries a C compiler (`tcc`, the riscv32 port in `jrrk2/tinycc`), musl's headers and static libraries, and
examples. `cc file.c -o /tmp/prog` is `tcc -static`; the board has a static C library only. Output must go to `/tmp`
(a 2 MB tmpfs); the root filesystem is read-only. A small program takes about 50 seconds to compile on the 50 MHz
soft core, so keep programs small.

* `/usr/src/` has `gfx.h` (a header-only library for the 160x128 LCD: `gfx_pixel`, `gfx_line`, `gfx_rect`,
  `gfx_circle`, `gfx_text` with an 8x8 font, `gfx_flip` to send the frame) and the demos `hello.c`, `plasma.c`, `mandel.c`,
  `life.c` and `fbview.c`. `/usr/src/build.sh` compiles every program there into `/tmp` (or `build.sh hello plasma` just those; `OUT=dir` changes the
  destination); then run `/tmp/hello`, `/tmp/plasma 60`. The binaries are gone after a reboot, so run it again.
  `fbview FILE [seconds]` shows a raw 160x128 RGB565 frame (40960 bytes) and needs a file name, or `-` for standard input;
  without one it waits for input from the terminal. Try `fbview /usr/share/sonata-logo.rgb565 10`, or
  `wget -q -O - http://192.168.1.169:8000/frame.raw.gz | zcat | fbview - 10`. Opening
  `/dev/fb0` hides the text console while the program runs.
* `photobox` is a slideshow of 15 astrophotographs built into the root filesystem (`/usr/share/photobox/*.raw`, 40960 bytes
  each, read straight from flash: no network, no decompression). `photobox 5` changes the interval from 8 s; Ctrl-C stops.
  `photobox 8 https://jrrk2.github.io/photobox` also fetches further pictures listed in that site's `frames.txt` in the
  background, each joining the show once it has arrived (https costs the board 20-45 s of CPU per file, and the downloads
  sit in `/tmp`, which is RAM). The pictures come from https://github.com/jrrk2/photobox (clone it next to synthgui, or
  set `PHOTOBOX=` for `make`).
* Ready-made pictures: `tools/img2fb.py picture.png frame.raw [--gz] [--stretch]` (Pillow for PNG/JPEG, plain PPM
  without it) makes a raw 160x128 RGB565 frame; serve it from the PC (`python3 -m http.server 8000`) and on the board run
  `fbget http://pc:8000/frame.raw 10`. `fbget` also takes `.raw.gz`, checks the size, and shows the frame for N seconds.
  BusyBox `wget` speaks HTTP and (with its built-in TLS, unauthenticated) HTTPS; there is no `curl`.
* DNS works because `/etc/resolv.conf` is a link to `/proc/net/pnp`, which the kernel fills from DHCP; `udhcpc` is also
  available, though the kernel (`ip=dhcp`) has already configured `eth0`.
* `showlogo [seconds]` shows the boot logo.
* **Nothing written on the board survives a reboot.** `/tmp` is a tmpfs (RAM) and the root filesystem is read-only; the
  flash is written only by the BIOS. Keep your work on the PC with TFTP: run `tools/tftpd.py` there, then on the board
  `tftp -p -l pi.c -r pi.c 192.168.1.169` saves a file to `<tftp root>/upload/pi.c` and `tftp -g -r pi.c 192.168.1.169`
  fetches it back (uploads never overwrite the served images). `nc host port < file` also works for one-off copies.

## Booting

The BIOS tries, in order: serial (SFL), flash, ROM, **kernel in flash**, then **TFTP over the KSZ8851**.

* **Standalone:** `kernel.bin` (4 KB M-mode stub + RAM kernel Image) in flash at `0x02000000` is copied to RAM at
  `0x40200000` and entered; the stub moves the Image to `0x40000000` and drops to S-mode. Linux mounts the romfs in
  the flash `rootfs` partition (`0x5C0000`) and starts `/sbin/init`, a shell script (busybox has no `init` applet).
  Boot takes about 40 s, no network needed. Press Q or ESC at the countdown for the BIOS prompt. The kernel configures
  the network itself (`ip=dhcp`, `CONFIG_IP_PNP_DHCP`; this busybox has no `udhcpc`), which waits for the link and the
  DHCP lease at boot.
* **LCD:** the panel is a 20x16 text console, or a 160x128 RGB565 frame buffer. The BIOS writes status lines and the kernel's `sonata_lcdcon` console (`linux/kernel/drivers/video/`) writes
  the last 15 kernel messages (timestamps stripped, lines cut at 20 columns) under a title bar with the uptime. The
  hardware scroll register rotates rows 1..15, so scrolling is one write.
* **Network:** `tftpboot` (or `tftpget <file> <addr>`, then `boot`/`flash_write`). The 8 DIP switches select the TFTP
  server: `0x00` is the built-in address (192.168.1.106, `--remote-ip`), any other value is the last octet on the same
  subnet. The switches are active low (ON = 0 on the pins), the BIOS inverts them. `linux/tools/tftpd.py` is a minimal
  TFTP server (port 69; macOS lets a normal user bind it).
* **Flashing:** `tftpflash <file> <offset>` (see step 6 of "Rebuilding everything"). The lower-level `tftpget`, `flash_erase_range`,
  `flash_write` and `mem_cmp` still exist; `flash_write` does not erase, and `mem_cmp` counts words, not bytes.

## Linux images (`linux/`)

`linux/images/` holds the built binaries: `stub.bin`, `kernel.bin`, `sonata-ram.dtb`, `rootfs.romfs`. `linux/Makefile`
rebuilds all of them from source (kernel `jrrk2/linux` at `af93851f1ec4d62f7f8c91b5399849c604c19144` with the patches
in `linux/kernel/`, the stub in `stub.S`, BusyBox 1.37.0 and musl 1.2.5 built with the same `riscv64-elf-gcc` and
`linux/userland/busybox.config`, tcc (the riscv32 port in `jrrk2/tinycc`, as in `jrrk2/buildroot`'s `package/tcc`) with one patch, the examples, and the rootfs assembled from all of these by `tools/romfs_add.py`); that is the
corresponding source for the GPL components; see `linux/SOURCES.md` for the exact revisions, tool versions, licences and
what the repository does not contain. The kernel builds on macOS with the host shims in `linux/kernel/hostinc`
and `ld.lld`.

## LCD frame buffer

`rtl/lcd_text.v` has two display modes. Text (default): a 20x16 character RAM at `0x80305000`, with the hardware scroll
register at `+0x140`. Frame buffer: a 160x128 RGB565 image at `0x80310000` (two pixels per 32-bit word, pixel 0 in the
low half; write-only, reads return zero; the gateware swaps red and blue for the panel's BGR order, so software uses
plain RGB565). The mode register is word 81 (`+0x144`, bit 0). While `/dev/fb0` is open the Linux driver
(`linux/kernel/drivers/video/fbdev/sonata_lcdfb.c`) sets frame buffer mode, so the text is hidden; closing the last
user brings it back. `showlogo [seconds]` (`/usr/bin/showlogo` in the rootfs, from `linux/userland/showlogo`) shows the boot logo. A diagnostic register at
`+0x148` (bit 0) shows a fixed red/green pattern in frame buffer mode instead of reading the RAM.
The frame buffer starts out holding the boot logo: `lcd_fb_ram.v` is ten directly instantiated RAMB36E1 whose
`INIT` parameters `linux/tools/gen_logo.py` fills from the logo image. From the BIOS prompt, `mem_write 0x80305144 1`
shows it and `mem_write 0x80305144 0` goes back to the text.

## Lessons from bring-up

* The stock stub writes PMP CSRs; this VexRiscv has none, so they trap and the CPU restarts the BIOS. `build_stub.sh
  -DNO_PMP` turns them into nops (the BIOS also patches them after a TFTP download).
* An XIP kernel from flash (and OpenSBI with `FW_RW_ADDR`) does not work here. Instruction fetch from the flash is fine
  (a 12 KB loop ran 6000 times without error), but the XIP kernel hangs early; QEMU's Sonata machine boots it, so the
  cause is VexRiscv-specific and not understood. OpenSBI with `FW_RW_ADDR=0x407F8000` overruns the 8 MB RAM
  (stacks for 2 harts + heap), which QEMU reproduces. The RAM kernel copied from flash is the supported route.
* The Verilator-based mapper dropped a true-dual-port RAM and a flop with an async reset feeding back on itself,
  silently; `rtl/spi_buf_ram.sv` and `spi_wb.sv` are written to avoid both.
* The mapper turns a dynamically indexed array of wires (`assign q = qb[sel]`) or a hierarchical reference into a
  generate block into a constant, silently: the frame buffer read as black until the block RAM outputs were ten
  plain wires chosen by a `case`. A memory written as arrays without `ram_style = "block"`, or with a read it does not
  recognise as synchronous, becomes distributed RAM (a 40 KB buffer then costs 11,000 LUTs and placement takes
  minutes). Directly instantiating RAMB36E1 (as in `lcd_fb_ram.v`) avoids both.
* Debugging with an initial value in the memory and a fixed-pattern register, instead of through the CPU, told the
  display path, the memory and the bus write path apart in three short hardware runs.
* A romfs directory is not just a list: genromfs makes the root's first entry `.` a directory pointing at itself and every
  other directory's `.` and `..` hard links to the directory entries in the parent lists. A generator that writes `.` as
  a plain hard link makes the kernel follow the link forever when it mounts the root, and the boot hangs without a
  message (`tools/romfs_add.py` now writes the genromfs structure; the hang reproduced in QEMU).
* A TFTP server that counts a duplicate ACK as a lost packet gives up when the BIOS pauses to flash a block, and
  retransmits in a burst; the cure is to ignore stale ACKs and resend only after a few seconds.
* `tcc` needs absolute `lui`/`addi` relocations to link the toolchain's libraries (see `linux/SOURCES.md`).

