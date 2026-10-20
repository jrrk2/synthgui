# synthgui -- proof of concept for an open FPGA flow GUI

A Qt 6 Widgets front end for the verilator synthesis flow:

    edit SV / XDC -> verilator --map-only-output (libabc in process)
    -> nextpnr-himbaechel -> fasm2netlist LVS -> prjxray bitstream -> openFPGALoader

```sh
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
* **Batch**: `--run <steps|all>` and `--screenshot <png> --view <name>`.

Next stages (not done): OpenSTA as a step (`virtex7.lib` from Vivado's SDK
for the arcs, nextpnr's `--sdf` for the delays); the LVS mismatches and
nextpnr's per-net timing as highlights on the plot; then the tools as shared
libraries in one process sharing one netlist and one chip database.

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
