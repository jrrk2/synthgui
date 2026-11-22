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

# Password crackers

The same retimed `crypt` round function run backwards: given a hashed `/etc/passwd` line,
recover the password by brute force.  This is the Morris-Thompson lesson -- a short
monocase password is found in seconds -- on the 100 MHz engine.

Both crackers reuse `crack2_des.svh` (the DES tables with **no** salt built in; the salt is
applied at run time) and `crack2_salt.svh` (expand the E permutation, then swap expanded bits
`k` and `k+24` for salt bit `k` -- the same effect as crypt swapping E-table entries, but
done per search instead of per build, so one bitstream cracks any of the 4096 salts).  The
search engine is `crypt_engine`'s C-slow ring (D = 8 candidates in flight, 25 iterations each,
one DES round cloud); the candidate letters, length, salt and target all ride the ring as
no-enable registers so the mapper can still retime the DES cloud forward.

## crack (single target)

`crack_top.sv` + `crack_engine.sv` sweep every lowercase string of 1..6 letters for one
target baked in at build time (`gen_crypt.py crack`), and print the recovered word on the
UART.  The demo target is `vienna`; the board finds it in 253,247,215 tries (~15 s at 100 MHz).

## crack2 (UART cracking service)

`crack2_top.sv` + `crack2_engine.sv` is the shipped service: send a 13-char `crypt(3)` line
(two salt chars, 11 hash chars, newline) and it sweeps every lowercase string of 1..6 letters
with that salt and replies

    OK cat    tries=00000822 ms=00000       (found: word, right-padded to 6, hex tries, decimal ms)
    NF        tries=132b7e36 ms=00080       (not found: not a <=6-letter lowercase word)

115200 8N1 on the USB-UART, same MMCM/clock as `crypt_top`.  The receiver is the carry-free
LFSR UART from `vc707_calc` (`uart_rx_lfsr`/`lfsr_div`/`slib_input_sync`); the transmitter is
`crypt_top`'s shift-out.  LED 0 found, 1 searching, 7 locked.  The alphabet is a compile-time
constant, so the odometer is a plain base-26 counter: this closes at 100.77 MHz.

`crack_harness.py` drives it from the host: it hashes words from a word list with a random
salt and checks the board recovers each one (`--count N` / `--all`, shortest first), or cracks
the DES lines of a real passwd file (`--passwd FILE`, skipping `*`/locked and `$...` modern
hashes).  Needs the port free (close picocom) and pyserial.

    python3 crack_harness.py --count 20            # 20 random words, verify each
    python3 crack_harness.py --passwd ./sample_passwd

## crack2_bram (configurable alphabet, RAM-backed)

`crack2_bram_top.sv` + `crack2_bram_engine.sv` make the alphabet run-time configurable: a
`%<32 hex>` line sets a 128-bit ASCII glyph mask.  The engine scans the mask once into a
compact index->code table and its odometer then counts indices, so there is no 128-bit
priority encoder on the per-cycle path.  The table is an **unpacked array**, which the mapper's
remap library maps to RAM (168 `RAM64X1D` distributed-RAM cells) rather than to muxes over a
flop vector; the design routes cleanly and closes at **122.20 MHz** -- faster than the fixed
lowercase build.  Verified on the board: with the alphabet set to `alnum`,

    python3 crack_harness.py --glyphs alnum --passwd ./alnum_passwd

recovers `x9`, `Ab3`, `cat1` and `Zz9` -- passwords the lowercase build cannot find.  Reads are
asynchronous (distributed RAM, so the engine stays combinational); a literal block RAM
(`RAMB36E1`) would need the read registered, one pipeline stage.  `--glyphs` takes a class
(`lower`/`upper`/`digits`/`alpha`/`alnum`/`printable`) or a literal set of characters.

## crack2_glyph (router-divergence demo)

`crack2_glyph_top.sv` + `crack2_glyph_engine.sv` are the same idea done the wrong way: the
index->code table is an 896-bit flop vector read by wide muxes.  It is correct in simulation
(`tb/tb_c2geng`, `tb/tb_c2ginner`: `OK a1 tries=0x900`) but **does not route** -- nextpnr's
congestion bottoms out then climbs away (`crack2_glyph_divergence.log`).  Kept as a clean
demonstration of router divergence, and of why `crack2_bram`'s unpacked-array/RAM form is the
fix: same function, one maps to RAM and routes at 122 MHz, the other maps to muxes and diverges.

| File | What it is |
|---|---|
| `crack2_top.sv` / `crack2_engine.sv` | shipped UART cracking service, fixed lowercase a..z, 100.77 MHz |
| `crack2_bram_top.sv` / `crack2_bram_engine.sv` | configurable alphabet, RAM table, 122.20 MHz (board-verified) |
| `crack2_glyph_top.sv` / `crack2_glyph_engine.sv` | same but flop-vector table: router-divergence demo |
| `crack2_des.svh` | DES tables, **unsalted** (`gen_crypt.py svh <out> base`) |
| `crack2_salt.svh` | run-time salt: expand E, swap bits k/k+24 per salt bit |
| `crack_top.sv` / `crack_engine.sv` | single-target build (the `vienna` demo) |
| `crack_harness.py` | host driver: dictionary verify, `--passwd` a real file, `--glyphs` set the alphabet |
| `crack2_glyph_divergence.log` | annotated nextpnr congestion trace (the demo's evidence) |
| `tb/tb_crack2.sv` `tb/tb_c2eng.sv` `tb/tb_c2beng.sv` `tb/tb_c2geng.sv` `tb/tb_c2ginner.sv` | testbenches |

`gen_crypt.py` grew `svh <out> base` (unsalted tables), `crack <out> <pw> [len]` (bake one
target), and `c2vec <out> <pw> <salt>` (a test vector for the engine/UART testbenches).
