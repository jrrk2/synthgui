# vc707_bramtest sources

Copied from bytecode at commit 8363dad so that `projects/vc707_bramtest.json` runs without that repository; flattened into one directory (no two files share a name). Each file keeps its own licence header.

Taken from the working tree, which had uncommitted changes in: fpga/bramtest/vc707_bramtest.v (the report prints once instead of repeating, and CPU_RESET reruns the test).

| here | from |
|---|---|
| bramtest.v | fpga/bramtest/bramtest.v |
| rom64k_w1.hex | fpga/bramtest/rom64k_w1.hex |
| rom64k_w32.hex | fpga/bramtest/rom64k_w32.hex |
| vc707_bramtest.v | fpga/bramtest/vc707_bramtest.v |
| vc707_bramtest_open.xdc | fpga/bramtest/vc707_bramtest_open.xdc |
| clkgen_vc707.sv | fpga/eth-rtl/clkgen_vc707.sv |
| simpleuart.v | fpga/eth-rtl/simpleuart.v |
