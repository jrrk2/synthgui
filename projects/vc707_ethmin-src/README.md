# vc707_ethmin sources

Copied from bytecode at commit 8363dad so that `projects/vc707_ethmin.json` runs without that repository; flattened into one directory (no two files share a name). Each file keeps its own licence header.

| here | from |
|---|---|
| axis_gmii_rx.sv | fpga/eth-rtl/axis_gmii_rx.sv |
| axis_gmii_tx.sv | fpga/eth-rtl/axis_gmii_tx.sv |
| clkgen_vc707.sv | fpga/eth-rtl/clkgen_vc707.sv |
| eth_gmii_retime256.sv | fpga/eth-rtl/eth_gmii_retime256.sv |
| eth_lutram_fifo.sv | fpga/eth-rtl/eth_lutram_fifo.sv |
| eth_mac_1g.sv | fpga/eth-rtl/eth_mac_1g.sv |
| eth_pkt_buf256.sv | fpga/eth-rtl/eth_pkt_buf256.sv |
| eth_stream_dma.sv | fpga/eth-rtl/eth_stream_dma.sv |
| liteeth_sgmii_phy.v | fpga/eth-rtl/liteeth_sgmii_phy.v |
| rgmii_lfsr.sv | fpga/eth-rtl/rgmii_lfsr.sv |
| sgmii_soc_liteeth.sv | fpga/eth-rtl/sgmii_soc_liteeth.sv |
| simpleuart.v | fpga/eth-rtl/simpleuart.v |
| fpu_hardfloat.v | fpga/fpu-rtl/fpu_hardfloat.v |
| hardfloat.v | fpga/fpu-rtl/hardfloat.v |
| recode64.v | fpga/fpu-rtl/recode64.v |
| sd_clock_divider.v | fpga/sd-lowrisc/sd_clock_divider.v |
| sd_cmd_serial_host.v | fpga/sd-lowrisc/sd_cmd_serial_host.v |
| sd_crc_16.v | fpga/sd-lowrisc/sd_crc_16.v |
| sd_crc_7.v | fpga/sd-lowrisc/sd_crc_7.v |
| sd_data_serial_host.sv | fpga/sd-lowrisc/sd_data_serial_host.sv |
| sd_defines.h | fpga/sd-lowrisc/sd_defines.h |
| sd_top.sv | fpga/sd-lowrisc/sd_top.sv |
| data.hex | fpga/vc707-ethmin/data.hex |
| data_bram.v | fpga/vc707-ethmin/data_bram.v |
| ethmin_vm_core.v | fpga/vc707-ethmin/ethmin_vm_core.v |
| globals.hex | fpga/vc707-ethmin/globals.hex |
| heap.hex | fpga/vc707-ethmin/heap.hex |
| program.hex | fpga/vc707-ethmin/program.hex |
| program.vh | fpga/vc707-ethmin/program.vh |
| program_bram.v | fpga/vc707-ethmin/program_bram.v |
| sd_wrap.v | fpga/vc707-ethmin/sd_wrap.v |
| tdp_ram32.v | fpga/vc707-ethmin/tdp_ram32.v |
| vc707_ethmin_vm.v | fpga/vc707-ethmin/vc707_ethmin_vm.v |
| vc707_ethmin_vm_open.xdc | fpga/vc707-ethmin/vc707_ethmin_vm_open.xdc |
| vm_trace.v | fpga/vc707-ethmin/vm_trace.v |
| ocaml4142_vm_rtl.sv | ocaml4142_vm_rtl.sv |
| state_rtl_complete.h | state_rtl_complete.h |
