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
* **Area**: the mapper's `%Info: map:` cell counts grouped into device
  resources (LUT, FF, RAMB36, LUTRAM, DSP, IO, BUFG) with utilisation of the
  part, before placement; after placement, nextpnr's own utilisation.
* **Timing**: Fmax per clock from nextpnr against its target, PASS / FAIL.
* **Chip**: every placed cell from nextpnr's placement JSON at its grid
  position, coloured by kind (block RAM / DSP drawn at their five-row size),
  the critical-path cells of failing clocks (or of the worst clock when all
  pass) drawn on top in red; mouse wheel zooms, drag pans.
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

The **Block RAM merit** step (`fom`, after Place & route) runs nextpnr's
`.github/scripts/bram_fom.py` on the placement: each block RAM's worst
estimated read path to the registers it feeds, from the placement alone.  The
Timing tab shows its worst and 95th percentile against the project's
`bram_fom_budget` ("worst/p95" in ps), and whether the two passes ran.  The
ROM-Linux project's budget, 6100/5400, is where the board drew the line:
every placement that read the ROM scored 5995 ps or less worst, the two that
did not 6251 and 6961.  The margin is about 250 ps, so a FAIL says "try this
one on the board", not "this one is broken".
Without a delay matrix file in the Delay model the step uses nextpnr's
fallback formula, whose scores are not comparable with a budget.

## OpenSTA step

Place & Route also writes the routed design (`--write`) and an SDF (`--sdf`).
The OpenSTA step runs `sta/nextpnr_sta.py`, which turns those into a flat Verilog
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
| `verilator` (jrrk2, `synthesis` branch) | `--map-only-output` synthesis |
| `yosys`, `nextpnr` (openXC7), `prjxray` (openXC7) | pinned to the commits the flow was proven on; `xc7/convert.py` drives prjxray |
| `fasm2netlist` | `tileverilog`, `lvs_equiv` |
| `prjxray-db` | segbits database (large) |
| `OpenSTA` | `sta` |
| `openFPGALoader` | programming |

`scripts/build-deps.sh [tool ...]` builds them into `build-deps/` and installs into
`build-deps/prefix`; the project files refer to the results as `{prefix}`, `{builds}` and
`{deps}`, which the GUI resolves relative to the checkout, so they work on Linux and macOS
alike. On macOS install the prerequisites with Homebrew first:

    brew install qt cmake boost eigen autoconf automake bison flex help2man tcl-tk@8 swig \
        libftdi libusb hidapi libffi pkgconf python

and configure the GUI with `cmake -S . -B build -DCMAKE_PREFIX_PATH=$(brew --prefix qt)`.
