# vc707_crypt sources

A demonstration of register retiming in synthesis, checked on the board: UNIX V7
`crypt(3)` (the password is the DES key, the salt swaps E-table entries, 25 encryptions
of a zero block) hashing passwords at 100 MHz.

`crypt_engine.sv` is a C-slow ring: D = 8 passwords in flight, eight ring registers, and
all sixteen DES rounds in one combinational cloud after the last of them.  Written that
way the design is far too slow for its clock; it relies on the mapper's retiming
(`synth.retime`) to spread the rounds across the eight registers.  The ring registers
have no enable or reset, which is what lets them move.

After each batch of 2^20 passwords the UART (115200 8N1, on the USB-UART) prints

    crypt("ZKuk1fZK","ab") = abpDHYAVhIFvw  sum e545a456ca810a94 PASS  pass 00000001 fail 00000000

the first password's hash, the sum of every hash in the batch, PASS when both are
libcrypt's, and the running pass and fail counts (about three lines a second).  LED 0
toggles per batch, LED 1 is any failure, LED 7 is the MMCM locked.  Check the hash with
`perl -e 'print crypt("ZKuk1fZK","ab")'`.

| File | What it is |
|---|---|
| `crypt_top.sv` | the board top: 200 MHz SYSCLK, MMCM to 1000 MHz / `CLK_DIV` (10: 100 MHz), the report line, UART |
| `crypt_engine.sv` | the ring (`D`, `ITER`, the batch size from `crypt_expect.svh`) |
| `crypt_des.svh` | DES tables and functions, salt "ab" built in; written by `gen_crypt.py svh` |
| `crypt_expect.svh` | batch size, password 0, salt and libcrypt's answers; written by `gen_crypt.py expect` |
| `gen_crypt.py` | the model, checked against the system libcrypt (`check`), and the two generators |
| `vc707_crypt.xdc` | pins and the 200 MHz clock |
| `tb/` | testbenches: `tb_engine` (the engine alone), `tb_top` (the whole design or a mapped netlist, decoding the UART) |

## Results

The same RTL at 100 MHz, with and without retiming (mapper margin 4 ns, `synth.timing_margin`;
retiming aims at the margin, so it is the lever for how far it goes):

| | no retiming | retimed |
|---|---|---|
| mapper estimate | 41.6 MHz | 153.1 MHz |
| nextpnr routed | 36.8 MHz | 111.2 MHz |
| OpenSTA setup / hold | -17.2 ns / met | +1.006 / +0.093 ns |
| LVS | 2152 proved, 0 differ | 4136 proved, 0 differ |
| flip-flops | 2113 | 4735 |
| on the board | FAIL every batch, a different wrong hash each time | PASS, 107 batches (112 million hashes) and counting |

With the default 1 ns margin retiming stops at an estimate of 111 MHz, which routes at
86 MHz; 3 ns routes at 97.7 MHz.  LVS only shows that the routed design is the mapped
netlist; that retiming kept the function is shown by simulating the netlist
(`tb_top` on `top_mapped.v`, a full batch: about 14 minutes) and by the board.

Needs the mapper with forward retiming of 7- and 8-input covers, retiming of whole
pipeline stages, and the fix for function results written by slices (the report's hex
digits come out as 0 without it); synthgui 0.1.4 pins a verilator that has them.

## Simulating

    verilator --binary -Wno-fatal -Wno-lint --top-module tb_engine -GD=8 -I. tb/tb_engine.sv crypt_engine.sv
    verilator --binary -O3 -Wno-fatal -Wno-lint -Wno-style --top-module tb_top -GDIV=1085 -I. \
        tb/tb_top.sv tb/sim_prims.v crypt_top.sv crypt_engine.sv ../../xc7/cells_sim.v

`tb_engine` hashes a batch of 256 (`-GN=` for others) and prints the sum and the first hash;
compare them with `python3 gen_crypt.py expect /dev/stdout 256`.  `tb_top` prints the report
line and TB PASS or TB FAIL.  For the mapped netlist put `top_mapped.v` from the work
directory in place of `crypt_top.sv crypt_engine.sv`.
