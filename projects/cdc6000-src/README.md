# cdc6000 sources

Copied from cdc6000 at commit a6a5700 so that `projects/cdc6000.json` runs without that repository; flattened into one directory (no two files share a name). Each file keeps its own licence header.

| here | from |
|---|---|
| mem.hex | fpga/vc707/mem.hex |
| simpleuart.v | fpga/vc707/simpleuart.v |
| vc707.xdc | fpga/vc707/vc707.xdc |
| vc707_cdc_top.v | fpga/vc707/vc707_cdc_top.v |
| cdc6000_core.sv | rtl/cdc6000_core.sv |
| cdc6000_sb.sv | rtl/cdc6000_sb.sv |
| cdc_pkg.sv | rtl/cdc_pkg.sv |
| hello.pas | host/tests/hello.pas |

## Running it on the board

The program in `mem.hex` is the 1972 Pascal compiler; it reads its input and
writes its listing in CDC display code over the UART (921600 baud, the
protocol in `vc707_cdc_top.v`'s header), which a terminal shows as garbage.
`cdcrun.py` speaks it: it reprograms the board (the compiler changes its own
memory, so it runs once per configuration), sends the source, and prints the
listing and the halt record.

    projects/cdc6000-src/cdcrun.py projects/cdc6000-src/hello.pas \
        --bit ~/synthgui-work/cdc6000/vc707_cdc_top.bit \
        --loader build-deps/prefix/bin/openFPGALoader

Built by synthgui's flow (Verilator, nextpnr with the clock-tree model and
block RAM placement, LVS 22233 proved and 0 differing), it compiles
hello.pas with no errors in 18980 instructions, the count the repository's
emulator (host/cdcemu) gives for the same memory image, and halts without a
fault.  Its character tables are the emulator's (host/cdcio.h), so a
listing from the board and one from cdcemu can be compared line for line.
