# synthgui -- proof of concept for an open FPGA flow GUI

A Qt 6 Widgets front end for the verilator synthesis flow:

    edit SV / XDC -> verilator --map-only-output (libabc in process)
    -> nextpnr-himbaechel -> fasm2netlist LVS -> prjxray bitstream -> openFPGALoader

```sh
git clone --recurse-submodules <url> synthgui    # or: git submodule update --init
scripts/build-deps.sh                            # tools from deps/ -> build-deps/
cmake -S . -B build && cmake --build build -j
build/synthgui --project projects/vc707_bramtest.json
build/synthgui --project projects/vc707_bramtest.json --run synth,pnr --screenshot chip.png --view chip   # batch, headless with QT_QPA_PLATFORM=offscreen
```

What it does today (stage one: every tool is a separate process):

* **Project file** (`projects/*.json`): sources, include dirs, defines,
  black boxes, constraints, device capacity, and one shell command template
  per pipeline step with `{name}` placeholders for any field and for the
  derived paths `{work} {json} {edif} {fasm} {placement} {bit} {sources}
  {incdirs} {defines} {blackboxes}`.  Steps change without rebuilding.
* **Editor**: file tree, tabbed editors with SystemVerilog / XDC
  highlighting, Ctrl+S saves.  Problems with a `file:line` open there.
* **Pipeline**: a toolbar button per step plus *Run all*; each step runs in
  the project's work directory, streams into the Log view, is saved as
  `<work>/<step>.log`, and shows ok / FAILED and its time in the status bar.
* **Settings** (*Settings...* in the application menu on macOS, Cmd+,; File menu elsewhere): one preference so far, per user and
  **off by default**: whether *Run all* writes the board's non-volatile memory. A step that does (the Sonata's `program_uf2`,
  which copies the UF2 to the SONATA drive, where the board writes it to flash; or any step with `"nonvolatile": true` in the
  project file) is left out of *Run all* and of `--run all` unless it is on, and the status bar (or stderr) says which. Its own
  toolbar button, and naming it (`--run program_uf2`), always run it. JTAG programming loads volatile memory and is not affected.
  The setting is in the user's preferences (`uk.kimmitt.synthgui` on macOS); `SYNTHGUI_SETTINGS=file.ini` uses a file instead.
* **Area**: the mapper's `%Info: map:` cell counts grouped into device
  resources (LUT, FF, RAMB36, LUTRAM, DSP, IO, BUFG) with utilisation of the
  part, before placement; after placement, nextpnr's own utilisation.
* **Timing**: Fmax per clock from nextpnr against its target, PASS / FAIL.
* **Chip**: every placed cell from nextpnr's placement JSON at its grid
  position, coloured by kind (block RAM / DSP drawn at their five-row size),
  the critical-path cells of failing clocks (or of the worst clock when all
  pass) drawn on top in red; mouse wheel zooms, drag pans.
* **Log**: the steps down the left, each coloured by its last result (green
  ok, red failed, amber running, grey a log of unknown result), and beside
  them the selected step's output; a running step's output streams into its
  own page and leaves the other steps' logs as they were.
* **Problems**: errors and critical warnings from every step's log.
* **Synthesis / Place & route options**: tabs beside the file list, one
  checkbox per tool option (unchecked leaves the tool's default), those that
  change the quality of results first -- the LUT mapping script; placer,
  timing weight, congestion spreading, delay model, clock tree delay model,
  block RAM placement, timing optimisation, router, rip-up, hold fixing,
  seed -- and the command line they make.  They
  are kept in the project's `options` and become `{synth_options}` (appended
  to the synthesis command) and `{nextpnr_flags}`; a project from before them
  has its `nextpnr_flags` read back into options.  The list is `options.h`.
* **Batch**: `--run <steps|all>` and `--screenshot <png> --view <name>`
  (views include `synthesis` and `pnr`, the option panels);
  `--set-option key=value` (repeatable, empty to turn off) changes an option
  in the project file, and `--print-command <step>` prints a step's command
  with the options applied -- for scripted QoR sweeps.

Next stages (not done): OpenSTA as a step (`virtex7.lib` from Vivado's SDK
for the arcs, nextpnr's `--sdf` for the delays); the LVS mismatches and
nextpnr's per-net timing as highlights on the plot; then the tools as shared
libraries in one process sharing one netlist and one chip database.

## Block RAM placement and its figure of merit

nextpnr's report can say a design with deep memories meets timing when it
does not: it gave every clock sink the same delay, so it saw no skew, and it
spread a ROM's block RAMs to the edges of the die.  The ROM-Linux SoC
(`projects/vc707_romlinux.json`) met 100 MHz by the report and read its ROM
wrongly on the board.  deps/nextpnr (the `clock-tree-bram-place` branch) adds
both fixes, on by default, as the Place & route panel's **Clock tree delay
model** and **Block RAM placement by read-mux group**.

The **Block RAM merit** step (`fom`, after Place & route) runs the built-in `bram-fom` tool
(`tools/bram_fom/`, from nextpnr's `.github/scripts/bram_fom.py`) on the placement: each block RAM's worst
estimated read path to the registers it feeds, from the placement alone.  The
Timing tab shows its worst and 95th percentile against the project's
`bram_fom_budget` ("worst/p95" in ps), and whether the two passes ran.  The
ROM-Linux project's budget, 6100/5400, is where the board drew the line:
every placement that read the ROM scored 5995 ps or less worst, the two that
did not 6251 and 6961.  The margin is about 250 ps, so a FAIL says "try this
one on the board", not "this one is broken".
Without a delay matrix file in the Delay model the step uses nextpnr's
fallback formula, whose scores are not comparable with a budget.

## LVS step

The LVS step extracts a netlist from the FASM (`tileverilog`) and proves it,
register by register, equal to the synthesis's.  The gold side is
Verilator's JSON itself (`lvs_equiv --gold <top>.json`): nothing converts it
to Verilog first.  The synthesis also writes the same netlist as Verilog,
`<work>/<top>_mapped.v`, for simulating it against the primitives' models.

On the ROM-Linux SoC it proves 70549 points with none differing: registers,
the register file and FIFOs in distributed RAM (RAM64X1D), and the 735
block RAMs' boundaries, contents and configuration.  Registers whose clock
is a constant (the unused JTAG bridge's) have no clock edge to compare, and
a RAM's address bit tied to one constant for both read and write (an 8-deep
FIFO in a 64-entry column) only picks the part of the RAM used; both are
counted and left out.

## OpenSTA step

Place & Route also writes the routed design (`--write`) and an SDF (`--sdf`).
The OpenSTA step runs the built-in `sta-prep` tool (`tools/sta_prep/`, from `sta/nextpnr_sta.py`), which turns those into a flat Verilog
netlist, a Liberty file and a Tcl script, then runs OpenSTA's `sta` on them.

nextpnr's SDF uses its own physical cell types (SLICE_LUTX, SLICE_FFX,
RAMB36E1_RAMB36E1, ...), which no vendor Liberty describes, so the Liberty is
derived from the SDF. Each IOPATH becomes an arc and each SETUPHOLD a check.
Instances with different arc sets get separate cell variants, so a LUT never
gains false arcs from unused inputs. Clocks default to every loaded BUFGCTRL
output at the slowest target in the nextpnr log; `--clock PIN=NS` overrides.

The Timing tab adds an "(OpenSTA)" row per clock, and the Critical path tab
shows OpenSTA's worst path, drawn on the chip plot between the placed cells.
On bramtest, OpenSTA agrees with nextpnr on nextpnr's own worst path to within
about 7%, but it finds a deeper path (an incrementer after the UART divider
compare) that nextpnr's report does not show.

## New projects

Run `build/synthgui` without `--project`, or press "New project..." on the toolbar, to
get the new-project dialog. Choose a flow template from `projects/`, which supplies the
toolchain paths, steps, part and black boxes. Then add sources with the file pickers.

- **Top module:** proposed from the modules no other source instantiates.
- **Include dirs:** added for directories that hold `.vh`/`.svh` headers.
- **Constraints:** an `.xdc` beside the sources is proposed, preferring one named after
  the top and the `_open` variant used by the nextpnr flow.
- **Memory init dir:** a source directory holding `.hex`/`.mem` images, else the first.
- **Work directory and project file:** default to `~/synthgui-work/<name>` and
  `projects/<name>.json`.

"Open existing..." in the dialog, or "Open project..." on the toolbar, opens a project
file in a new window.

## Dependencies and macOS

The tools the flow calls are submodules under `deps/`:

| submodule | provides |
| --- | --- |
| `verilator` (jrrk2, `synthesis` branch) | `--map-only-output` synthesis; `--map-only-verilog` the same netlist as structural Verilog |
| `nextpnr` (openXC7), `prjxray` (openXC7) | pinned to the commits the flow was proven on; prjxray's `xc7frames2bit` makes the bitstream from the frames the built-in `fasm2frames` writes |
| `fasm2netlist` (jrrk2, `lvs-verilator-json`) | `tileverilog`, `lvs_equiv` |

### Built-in tools

The converters between the big tools are part of synthgui, so the flow runs without Python: a step's command names
one as `@name` (project variables `{fasm2frames}`, `{bit2uf2}`, `{sta_prep}`, `{bram_fom}`) and synthgui runs it in a worker
thread, its output going to the step's log. Commands before and after it in a `&&` chain run through bash as before. The
programs with their own maintainers (verilator, nextpnr, OpenSTA, prjxray's `xc7frames2bit`, fasm2netlist, openFPGALoader)
stay separate executables, started as processes.

| tool | what it does | the program it is checked against |
| --- | --- | --- |
| `fasm2frames` (`tools/fasm2frames/`) | FASM to frames, with prjxray's IO-bank and glue rules (a port of prjxray's `utils/fasm2frames.py`, ISC licence, notice kept) | `xc7/fasm2frames_fast.py` |
| `bit2uf2` (`tools/bit2uf2/`) | wraps a bitstream in UF2 blocks for the Sonata board's SONATA drive | `xc7/bit2uf2.py` |
| `sta-prep` (`tools/sta_prep/`) | nextpnr's routed JSON and SDF to a Liberty file, a Verilog netlist and the Tcl `sta` reads | `sta/nextpnr_sta.py` |
| `bram-fom` (`tools/bram_fom/`) | the block RAM figure of merit | `deps/nextpnr/.github/scripts/bram_fom.py` |

Each is also a command, `build/synthgui --tool NAME args`, for scripts and for the checks: `tools/*/compare.sh` runs the
Python original and the tool on the same inputs and compares the outputs byte for byte (every FASM, netlist and placement
in `~/synthgui-work` gave identical results, on Artix-7 and Virtex-7). The Python files stay in the tree as the reference.

The Xilinx primitive models Verilator reads as cell stubs, and that the
mapped Verilog simulates against, are `xc7/cells_sim.v` and
`xc7/cells_xtra.v`: yosys's (ISC licence, kept in their headers), copied in
so that the flow needs no yosys at all.
| `prjxray-db` | segbits database (large) |
| `OpenSTA` | `sta` |
| `openFPGALoader` | programming |

`scripts/build-deps.sh [tool ...]` builds them into `build-deps/` and installs into
`build-deps/prefix`; the project files refer to the results as `{prefix}`, `{builds}` and
`{deps}`, which the GUI resolves relative to the checkout, so they work on Linux and macOS
alike. On macOS install the prerequisites with Homebrew first:

    brew install qt cmake boost eigen autoconf automake bison flex help2man tcl-tk@8 swig \
        libftdi libusb hidapi libffi pkgconf

and configure the GUI with `cmake -S . -B build -DCMAKE_PREFIX_PATH=$(brew --prefix qt)`.

### CI

`.github/workflows/flow.yml` builds synthgui and runs the example projects' flow on Ubuntu 24.04 on every push that
changes the source (GUI, `tools/`, `projects/`, `xc7/`, `sta/`, the submodule pointers, `build-deps.sh`): one job per
project, every step but programming, its logs and bitstream kept as an artifact and a step table in the job summary.
`scripts/ci-flow.sh PROJECT...` is that run, and works locally too. The tools are built once per set of submodule commits
and cached. The long designs (cdc6000, the Ethernet and ROM-Linux SoCs) run weekly, or from *Run workflow* with projects `long`.

Each project is also checked for what a step's exit status does not say: nextpnr met every clock target, and the FASM and
frames are the ones recorded for the platform in `ci/expected/<platform>.txt` (`Darwin-arm64.txt`, `Linux-x86_64.txt`). The
same inputs give the same FASM and frames on a machine, so a changed hash means a changed flow (a tool, a project, a
submodule); if that is intended, `CI_BASELINE=update scripts/ci-flow.sh PROJECT...` records the new hashes, to be committed.
A platform with no file is not checked for the hashes. A step known to fail can be left out of one project in `ci/skip-steps.txt` (project, step, reason); the step table lists it as
skipped, with the reason, so it is never silent (none at present: `vc707_bramtest`'s LVS was one until `fasm2netlist` traced its unused clock buffer). The jobs upload `hashes.txt` (same format) with the logs, to refresh
a platform from its runner. `scripts/ci-flow.sh` runs in `ci-work/`, not the project's own work directory, so it is safe to
run on a development machine. The quick set also runs on macOS arm64, the release platform, in one job that does not fail
the run yet: it has not been through a GitHub runner.

### Linux package

    scripts/package-linux.sh                    # build-release/synthgui-VERSION-linux-x86_64{/,.tar.gz}

makes a folder for Ubuntu 24.04 with the tools, the chip databases and the prjxray-db families (`FAMILIES`) inside,
and the Qt synthgui was built against in `lib/` and `plugins/` (`bin/qt.conf` keeps the system's Qt plugins out;
Ubuntu 24.04's own Qt is 6.4). The other libraries are Ubuntu's, installed with apt as `README-Linux.txt`
(`scripts/README-Linux.txt`) lists, along with the udev rule openFPGALoader needs. On other distributions build from
source as above.

### Windows

Everything, the GUI and the tools, builds as native programs with MSYS2's MINGW64 toolchain. MSYS2 is needed to
build, not to run: its shell, make, autoconf, bison, flex and perl configure and generate, and MINGW64 gcc compiles.
Install [MSYS2](https://www.msys2.org), then in a MINGW64 shell:

    pacman -S --needed make autoconf automake libtool bison flex help2man git patch gperf \
        zip mingw-w64-x86_64-{gcc,cmake,ninja,pkgconf,boost,eigen3,tcl,swig,zlib,python,readline,dlfcn,z3,qt6-base,qt6-tools}
    git config --global core.autocrlf false     # before cloning: CRLF breaks the autotools and generator scripts
    git clone --recurse-submodules https://github.com/jrrk2/synthgui.git && cd synthgui
    JOBS=3 scripts/build-deps.sh                # JOBS: each compile can take 1 GB; the default is every CPU
    cmake -S . -B build -G Ninja && cmake --build build
    scripts/package-windows.sh                  # build-release/synthgui-VERSION-windows-x64/

On Windows `build-deps.sh` also builds libusb, hidapi and libftdi for openFPGALoader (MSYS2 no longer packages them
for MINGW64) and skips the Python venv, which nothing in the flow uses. Each build of the GUI copies Qt and the DLLs
`build/synthgui.exe` loads beside it (`windeployqt` and `scripts/windows-deploy.cmake`; `-DSYNTHGUI_DEPLOY=OFF` skips
that), so it also starts from File Explorer; the steps it runs find the tools' DLLs in `C:\msys64\mingw64\bin`
(`MSYS2_ROOT` if MSYS2 is elsewhere).
`scripts/package-windows.sh` makes a folder that needs none of it: Qt, the tools, their DLLs, Tcl's library and the
prjxray-db families (`FAMILIES`) are all inside, and `bin/synthgui.exe` runs from any location.

synthgui runs a step's command itself on Windows: each `&&` part is a `VAR=value` prefix and a program started
directly, or `cd`, `mkdir -p`, `cp` or `sync` done in-process. Only a command with more shell than that (pipes,
redirection, `$`) is passed to bash, which then has to be installed (Git for Windows or MSYS2). The project files'
steps need no shell. The Sonata *Program* step copies to `/Volumes/SONATA`, the macOS mount point of the board's drive;
on Windows change it to the drive letter.

openFPGALoader reaches a board's FTDI chip through libusb, which Windows only lets open an interface bound to WinUSB;
out of the box all of them have FTDI's serial driver. Once per board, run [Zadig](https://zadig.akeo.ie), choose
*Options → List All Devices*, pick the JTAG interface (on the Sonata *Sonata (Interface 0)*, USB ID `0403 6011 00`)
and replace its driver with WinUSB. Leave the other interfaces alone: they are the board's serial ports. The package
carries these steps for its users in `README-Windows.txt` (`scripts/README-Windows.txt`).

`.github/workflows/windows-release.yml` makes the same package on GitHub's Windows runners, from source with nothing
cached: run it from the Actions tab for a test build (the zip is the run's artifact), or push a `v*-windows` tag for a
draft release to check and publish. It is set up for signing by [SignPath Foundation](https://signpath.org), which
signs only builds made this way: once the project is accepted, the secret `SIGNPATH_API_TOKEN` and the variables
`SIGNPATH_ORGANIZATION_ID`, `SIGNPATH_PROJECT_SLUG` and `SIGNPATH_SIGNING_POLICY_SLUG` turn it on, with
`.signpath/artifact-configuration.xml` as the project's artifact configuration (it signs `synthgui.exe`).
`RELEASE-WINDOWS.md` is the release procedure: making, checking, signing and publishing a Windows release.

The GUI alone also builds with the Qt installer's kits (MSVC 2022 or MinGW) and no submodules:
`cmake -S . -B build -DCMAKE_PREFIX_PATH=C:/Qt/6.x.x/msvc2022_64 && cmake --build build --config Release`, then
`windeployqt --release build/Release/synthgui.exe`.

## macOS release

`scripts/package-macos.sh` builds `build-release/synthgui.app` (Qt bundled by `macdeployqt`), puts the tools the flow runs
into `Contents/Resources` with their libraries relocated (`scripts/bundle-tools.py`: verilator, nextpnr and its chip
databases, fasm2netlist, `xc7frames2bit`, OpenSTA with Tcl's script library, openFPGALoader, and the artix7 and virtex7
parts of prjxray-db; `FAMILIES="artix7 virtex7 kintex7"` changes that), signs every Mach-O with your Developer ID
Application identity and the hardened runtime, and writes `synthgui-VERSION-macos-arm64.zip`. There is no Python in it.
With `NOTARY_PROFILE=name` (made once with `xcrun notarytool store-credentials name`) it notarizes and staples as well.
The bundle runs from any location, with nothing from Homebrew and no Perl or Python: only the macOS system libraries and
the basic shell utilities come from the host. It needs macOS 26 or later because the Homebrew Qt it bundles does.

## Code signing policy

Windows releases are built from this repository's source by `.github/workflows/windows-release.yml` on GitHub-hosted
runners, and are to be signed by [SignPath Foundation](https://signpath.org) through [SignPath.io](https://signpath.io)
(applied for; until then the Windows zip is unsigned and says so in its release notes). Only synthgui's own program,
`bin/synthgui.exe`, is signed. The tools bundled with it (verilator, nextpnr, OpenSTA, prjxray, openFPGALoader,
fasm2netlist) and the MINGW64 and Qt libraries are other projects' builds, made from source in the same workflow, and
are not signed.

Team roles:

- Committers and reviewers: Jonathan Kimmitt (jrrk2)
- Approvers: Jonathan Kimmitt (jrrk2)

Every signing request is approved by hand.

Privacy policy: this program will not transfer any information to other networked systems unless specifically
requested by the user or the person installing or operating it.

## Licence

synthgui is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License,
version 3, as published by the Free Software Foundation (`LICENSE`). Files that carry their own licence notice keep it:
yosys's Xilinx cell models in `xc7/` and the prjxray rules ported into `tools/fasm2frames` (ISC), and third-party HDL
in the example projects (`projects/`; for example ISC, MIT and Apache-2.0). The tools in `deps/` are separate projects
under their own licences.
