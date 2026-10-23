# Corresponding source and how to reproduce the binaries

`images/` holds four binaries. This file says what each is made from, where every source lives, which versions were
used, and what is **not** in this repository. `make -C linux` (see `Makefile`) is the build script; the top-level
`README.md` has the SoC, bitstream and flashing steps.

## What is in each binary

| File | Contents | Licence of the contents | Source |
|---|---|---|---|
| `images/kernel.bin` | `stub.bin` (4 KB) followed by the Linux `Image` | stub: see below; Linux: GPL-2.0-only | below |
| `images/stub.bin` | M-mode stub: SBI timer/IPI/HSM calls, trap forwarding | from lowRISC `sonata-system` via `jrrk2/sonata-linux`; the licence of that tree applies (the file itself carries no header) | `stub.S`, `stub.ld`, `build_stub.sh` here |
| `images/sonata-ram.dtb` | device tree, also built into the kernel | from `sonata-system/linux/dts/sonata-ram.dts` plus the `lcd` node and `ip=dhcp` added here | `kernel/sonata-ram.dts` |
| `images/rootfs.romfs` | read-only root filesystem | busybox (GPL-2.0-only), iperf3 (BSD-3-Clause), other programs, see "Root filesystem" | see "Root filesystem" |

The BIOS (in the bitstream, not in `images/`) is LiteX's BIOS (BSD-2-Clause) plus `bios/spieth_boot.c`; the CPU is
VexRiscv (MIT, generated with SpinalHDL, MIT). Neither is GPL.

## Linux kernel (kernel.bin)

* **Upstream source:** `https://github.com/jrrk2/linux.git`, commit `af93851f1ec4d62f7f8c91b5399849c604c19144`
  ("Optimise flash offsets"), version string `6.9.0`. It is not copied into this repository: `make -C linux` fetches
  exactly that commit (`git fetch --depth 1 origin <commit>`; use `git -c http.version=HTTP/1.1` if GitHub's HTTP/2
  fails, the Makefile already does).
* **Files in this repository that are part of the kernel build** (all under `linux/kernel/`):
  `ram-additions.config` (merged onto `tinyconfig`; the Makefile applies the remaining `scripts/config` options),
  `sonata-ram.dts` (built into the kernel as `arch/riscv/boot/dts/litex/sonata.dtb`),
  `drivers/spi/spi-opentitan.c`, `drivers/net/ethernet/micrel/ks8851_{common,spi}.c` and `ks8851.h`
  (these replace the files of the same name in the tree), and `drivers/video/sonata_lcdcon.c` (new, GPL-2.0; the
  Makefile adds `obj-y += sonata_lcdcon.o` to `drivers/video/Makefile`).
  The macOS-only host header shims `kernel/hostinc/{elf.h,byteswap.h}` are build aids, not part of the kernel image
  (`elf.h` is musl's).
* **Command:** `make -C linux images/kernel.bin` (inside it: `tinyconfig`, `merge_config.sh`, `scripts/config`,
  `olddefconfig`, `make Image`, then `cat stub.bin Image`). The effective `.config` is regenerated, not stored.
* **Not bit-identical:** the kernel embeds its build time, user and host in `Linux version ...`, so a rebuild is
  functionally the same but differs in those strings. Set `KBUILD_BUILD_TIMESTAMP`, `KBUILD_BUILD_USER` and
  `KBUILD_BUILD_HOST` to pin them. The committed image was built on macOS with the tools listed below.

## Root filesystem (rootfs.romfs)

`images/rootfs.romfs` = `rootfs-base.romfs` + one added file, `/sbin/init`, a shell script (`tools/romfs_add.py`
rewrites the romfs; it is a small Python program included here).

`rootfs-base.romfs` is the busybox/iperf3 userland from the `sonata-linux` project (`github.com/jrrk2/sonata-linux`,
`make rootfs` = `genromfs` of Buildroot's target directory, Buildroot external tree in
`linux-on-litex-vexriscv/buildroot`, defconfig `litex_vexriscv_sonata_defconfig`). **It was supplied as a binary and
was not built from this repository.** Its programs include BusyBox v1.36.1 (GPL-2.0-only; its banner reads
`BusyBox v1.36.1 (2026-02-16 07:52:06 GMT)`), iperf3, `netbench` and `fb_fractal`. The complete source of those
programs is the Buildroot package set used by that build: BusyBox 1.36.1 from `https://busybox.net/downloads/`, the
Buildroot revision, defconfig and busybox config of the `sonata-linux` checkout that produced the file, and the
other packages' tarballs. **What this repository does not record** is that checkout's exact revision and busybox
configuration. The binary here is a static-PIE built with compressed instructions, while the
`litex_vexriscv_sonata_defconfig` in the `sonata-linux` tree sets `BR2_RISCV_ISA_RVC=n`, so the configuration that built
this file differs from that defconfig in some way that is not recorded here. Whoever distributes this repository
must supply, or offer, that source (GPL-2.0 section 3); the maintainer who provided the file is the only one who
has it.

## Versions used for the committed images and bitstream

| What | Version |
|---|---|
| Cross compiler / linker | `riscv64-elf-gcc` 15.2.0, GNU ld 2.45 (Homebrew), `-march=rv32ima_zicsr_zifencei -mabi=ilp32` (kernel via the Linux build) |
| Kernel link step (macOS) | Homebrew LLD 23.1.4 (`LD=ld.lld`; the bare-metal GNU ld cannot link the vdso with `-shared`) |
| Device tree compiler | DTC 1.8.1 |
| make / Python / JDK | GNU Make 4.4.1, Python 3.12.14 (venv: `packaging pyyaml requests pyserial`), OpenJDK 21 for sbt |
| LiteX | `https://github.com/jrrk2/litex` @ `b91b9c6bb` (a fork; plain upstream LiteX has not been tried) |
| LiteEth | `https://github.com/jrrk2/liteeth` @ `80d86b103` |
| migen | `https://github.com/m-labs/migen` @ `e19524c96` |
| LiteDRAM | `https://github.com/enjoy-digital/litedram` @ `3cf585a60` |
| litespi | `https://github.com/litex-hub/litespi` @ `4c0456417` |
| pythondata-cpu-vexriscv-smp | `litex-hub/pythondata-cpu-vexriscv-smp` @ `0a97182af` (VexRiscv `625fc8437`, SpinalHDL `002ffd50b`) |
| pythondata-software-picolibc / -compiler_rt | `litex-hub/...` @ `6a13ccce7` / `6eb76609c` |
| Open FPGA flow | this repository (`build/synthgui`: Verilator mapper, nextpnr-himbaechel, prjxray) at the commit that contains these files; OpenSBI, QEMU and the Vivado flow are not used |

## Reproduce, in order

1. Check out this repository and build its tools (top-level README); install the tool versions above.
2. `make -C projects/sonata_romlinux-src/linux` rebuilds `images/` from the pinned kernel commit (needs network
   for the kernel fetch; the Buildroot-built `rootfs-base.romfs` is included as a binary, see above).
3. Rebuild the SoC and bitstream and flash everything as in `projects/sonata_romlinux-src/README.md`
   ("Rebuilding everything"). `make -C linux flash` prints the BIOS commands with the exact sizes.
