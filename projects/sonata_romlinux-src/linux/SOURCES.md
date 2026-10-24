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
| `images/rootfs.romfs` | read-only root filesystem | BusyBox 1.37.0 (GPL-2.0-only), musl 1.2.5 (MIT), tinycc (LGPL-2.1+), the examples; all built here | see "Root filesystem" |

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

`images/rootfs.romfs` is built entirely from source in this repository by `make -C linux`; nothing in it is a supplied
binary. `tools/romfs_add.py` starts from an empty romfs and adds:

* **BusyBox 1.37.0 and musl 1.2.5**, from the upstream tarballs (`https://busybox.net/downloads/busybox-1.37.0.tar.bz2`,
  `http://musl.libc.org/releases/musl-1.2.5.tar.gz`), with the Linux kernel headers installed from the kernel tree above.
  The BusyBox configuration is `userland/busybox.config` (BusyBox `defconfig` with `STATIC`, `HUSH` as `sh`,
  `FEATURE_SH_STANDALONE`, `FEATURE_PREFER_APPLETS` and `FEATURE_USE_INITTAB` on; `TC` and `HWCLOCK` (riscv32 has no
  `settimeofday` syscall) and the x86 SHA hardware acceleration off). No BusyBox or musl source is modified.
* **tcc, the Tiny C Compiler**, so programs can be compiled on the board: `https://github.com/jrrk2/tinycc.git` at
  commit `f7e187ef8084d49fd458a5ecba54868cce24f62c` (the `riscv32` port), configured exactly as `package/tcc/tcc.mk` in
  `jrrk2/buildroot` does (`--cpu=riscv32 --targetos=Linux --config-musl --elfinterp=/lib/ld-musl-riscv32.so.1
  --crtprefix=/usr/lib --sysincludepaths=/usr/include --libpaths=/usr/lib/tcc:/usr/lib --with-libgcc`; `c2str.exe` built
  on the host, `libtcc1.a` built by the cross gcc), plus one patch, `userland/tcc-riscv32-abs-relocs.patch`. The patch adds
  the absolute `R_RISCV_HI20`, `LO12_I` and `LO12_S` relocations to `riscv32-link.c`: GCC's default 32-bit RISC-V
  code model (`medlow`) uses them, so without them `tcc` cannot link against `libc.a` or the toolchain's `libgcc.a`.
  A second patch, `userland/tcc-static-libgcc.patch`, makes `tcc` link `libgcc.a` (the soft-float, `long double` and
  64-bit division helpers) in a static link too: upstream adds it only for dynamic links, and it has to come after
  `libc.a` because an archive is scanned once, in order. And one configure flag is added to the recipe's,
  `--tcc-switches=-static`, because the board has a static libc only (no musl loader), so a dynamically linked `a.out`
  cannot run. Both are in the rootfs image but had not been run on the board when this was written: on the board,
  `tcc -static pi.c -lc /usr/lib/libgcc.a` (the same link order) was verified to build and run a float `printf` program.
  `tools/stage_tcc.py` lays out the on-board tree (`/usr/bin/tcc`, `/usr/lib/tcc/{libtcc1.a,include}`, musl's headers,
  the kernel headers a program needs, `crt*.o`, stripped `libc.a` and `libgcc.a`). The `cc` command is `tcc -static`.
* **Files from this repository**: `userland/skeleton/` (`/etc/inittab`, `profile`, `passwd`, `group`, `hosts`),
  `userland/src/` (`/usr/src`: `gfx.h`, the demos and `build.sh`), `userland/{showlogo,fbget,cc,photobox}`, the photographs for `/usr/share/photobox` (from https://github.com/jrrk2/photobox, the author's own work: `frames/*.raw.gz` unpacked by `make`), the logo (`tools/gen_logo.py`), the
  `/sbin/init` script (written by `tools/romfs_add.py`), the directories and device nodes listed in `linux/Makefile`,
  BusyBox's own `examples/udhcp/simple.script` for `udhcpc`, and `/etc/resolv.conf` as a link to `/proc/net/pnp`.

Programs the earlier rootfs had and this one dropped, because they were supplied binaries with no source in reach:
`netbench`, `fb_fractal`, and `iperf3` (the sources of the first two were not found; `iperf3` is public source, but it needs
64-bit atomics, so on 32-bit RISC-V a `libatomic`, which this toolchain does not ship. A small shim of the `__atomic_*_8`
functions would let `iperf-3.17.1` build with `./configure --host=riscv32-linux-musl --disable-shared
--enable-static-bin --without-openssl`).

## Versions used for the committed images and bitstream

| What | Version |
|---|---|
| Cross compiler / linker | `riscv64-elf-gcc` 15.2.0, GNU ld 2.45 (Homebrew), `-march=rv32ima_zicsr_zifencei -mabi=ilp32` (kernel via the Linux build) |
| Kernel link step (macOS) | Homebrew LLD 23.1.4 (`LD=ld.lld`; the bare-metal GNU ld cannot link the vdso with `-shared`) |
| Device tree compiler | DTC 1.8.1 |
| Userland sources | musl 1.2.5, BusyBox 1.37.0 (tarballs fetched by the Makefile with `curl`), jrrk2/tinycc @ `f7e187ef8084` |
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
2. `make -C projects/sonata_romlinux-src/linux` rebuilds `images/` from the pinned kernel commit, the musl and
   BusyBox tarballs and the pinned tinycc commit (needs network for those fetches).
3. Rebuild the SoC and bitstream and flash everything as in `projects/sonata_romlinux-src/README.md`
   ("Rebuilding everything"). `make -C linux flash` prints the BIOS commands with the exact sizes.
