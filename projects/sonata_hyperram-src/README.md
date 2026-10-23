# sonata_hyperram

8 MB RAM test of the Sonata board's W956D8MBYA HyperRAM, results on the LCD.  `top.v` documents the display lines, `hr_ramtest.v` the test.  The HyperRAM controller is LiteX's (`../sonata-lib/hyperram.v`).

Checked in simulation (Verilator) against lowRISC sonata-system's `dv/models/hyperram/rtl/hyperram_W956.sv`, with its OpenTitan RAM replaced by an array and register reads added: all four phases, no errors, chip select low at most 1.74 us (limit 4 us); the other latency settings, which fail, show the test notices.  The model is not part of this repository.

Clocks: 25 MHz in, 80 MHz for the core (HyperRAM clock 20 MHz), 25 MHz for the LCD.  Pins from sonata-system `data/pins_sonata.xdc`.
