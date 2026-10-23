# sonata_bramtest sources

`bramtest.v` and `rom64k_w1.hex` are copied unchanged from bytecode's `fpga/bramtest/` at commit c29b934 (clean tree) so that `projects/sonata_bramtest.json` runs without that repository.  The same `bram_case` as `vc707_bramtest`, whose copy matches.  `top.v` is new: the Sonata top, with the results on the LCD (`../sonata-lib/`) instead of the UART, and the shapes cut to fit the XC7A50T's 75 RAMB36 (see its header comment).
