create_clock -period 40.000 -name clk25 [get_ports clk25]
################################################################################
# IO constraints
################################################################################
# serial:0.tx
set_property LOC C17 [get_ports {serial_tx}]
set_property IOSTANDARD LVCMOS33 [get_ports {serial_tx}]

# serial:0.rx
set_property LOC D18 [get_ports {serial_rx}]
set_property IOSTANDARD LVCMOS33 [get_ports {serial_rx}]

# clk25:0
set_property LOC P15 [get_ports {clk25}]
set_property IOSTANDARD LVCMOS33 [get_ports {clk25}]

# nrst:0
set_property LOC T5 [get_ports {nrst}]
set_property IOSTANDARD LVCMOS33 [get_ports {nrst}]

# hyperram:0.dq
set_property LOC B1 [get_ports {hyperram_dq[0]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_dq[0]}]

# hyperram:0.dq
set_property LOC E2 [get_ports {hyperram_dq[1]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_dq[1]}]

# hyperram:0.dq
set_property LOC H1 [get_ports {hyperram_dq[2]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_dq[2]}]

# hyperram:0.dq
set_property LOC A1 [get_ports {hyperram_dq[3]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_dq[3]}]

# hyperram:0.dq
set_property LOC E1 [get_ports {hyperram_dq[4]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_dq[4]}]

# hyperram:0.dq
set_property LOC B2 [get_ports {hyperram_dq[5]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_dq[5]}]

# hyperram:0.dq
set_property LOC C1 [get_ports {hyperram_dq[6]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_dq[6]}]

# hyperram:0.dq
set_property LOC D2 [get_ports {hyperram_dq[7]}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_dq[7]}]

# hyperram:0.rwds
set_property LOC F1 [get_ports {hyperram_rwds}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_rwds}]

# hyperram:0.cs_n
set_property LOC J2 [get_ports {hyperram_cs_n}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_cs_n}]

# hyperram:0.rst_n
set_property LOC C2 [get_ports {hyperram_rst_n}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_rst_n}]

# hyperram:0.clk_p
set_property LOC H2 [get_ports {hyperram_clk_p}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_clk_p}]

# hyperram:0.clk_n
set_property LOC G2 [get_ports {hyperram_clk_n}]
set_property IOSTANDARD LVCMOS18 [get_ports {hyperram_clk_n}]

# spiflash4x:0.cs_n
set_property LOC D10 [get_ports {spiflash4x_cs_n}]
set_property IOSTANDARD LVCMOS33 [get_ports {spiflash4x_cs_n}]

# spiflash4x:0.clk
set_property LOC A8 [get_ports {spiflash4x_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {spiflash4x_clk}]

# spiflash4x:0.dq
set_property LOC C11 [get_ports {spiflash4x_dq[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spiflash4x_dq[0]}]

# spiflash4x:0.dq
set_property LOC C10 [get_ports {spiflash4x_dq[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spiflash4x_dq[1]}]

# spiflash4x:0.dq
set_property LOC A10 [get_ports {spiflash4x_dq[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spiflash4x_dq[2]}]

# spiflash4x:0.dq
set_property LOC A9 [get_ports {spiflash4x_dq[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spiflash4x_dq[3]}]

# spi_eth:0.clk
set_property LOC E3 [get_ports {spi_eth_clk}]
set_property IOSTANDARD LVCMOS18 [get_ports {spi_eth_clk}]

# spi_eth:0.mosi
set_property LOC D5 [get_ports {spi_eth_mosi}]
set_property IOSTANDARD LVCMOS18 [get_ports {spi_eth_mosi}]

# spi_eth:0.miso
set_property LOC D4 [get_ports {spi_eth_miso}]
set_property IOSTANDARD LVCMOS18 [get_ports {spi_eth_miso}]

# spi_eth:0.cs_n
set_property LOC H5 [get_ports {spi_eth_cs_n}]
set_property IOSTANDARD LVCMOS18 [get_ports {spi_eth_cs_n}]

# eth_rst_n:0
set_property LOC J5 [get_ports {eth_rst_n}]
set_property IOSTANDARD LVCMOS18 [get_ports {eth_rst_n}]

# user_sw:0
set_property LOC D12 [get_ports {user_sw[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_sw[0]}]
set_property PULLTYPE PULLUP [get_ports {user_sw[0]}]

# user_sw:0
set_property LOC D13 [get_ports {user_sw[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_sw[1]}]
set_property PULLTYPE PULLUP [get_ports {user_sw[1]}]

# user_sw:0
set_property LOC B16 [get_ports {user_sw[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_sw[2]}]
set_property PULLTYPE PULLUP [get_ports {user_sw[2]}]

# user_sw:0
set_property LOC B17 [get_ports {user_sw[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_sw[3]}]
set_property PULLTYPE PULLUP [get_ports {user_sw[3]}]

# user_sw:0
set_property LOC A15 [get_ports {user_sw[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_sw[4]}]
set_property PULLTYPE PULLUP [get_ports {user_sw[4]}]

# user_sw:0
set_property LOC A16 [get_ports {user_sw[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_sw[5]}]
set_property PULLTYPE PULLUP [get_ports {user_sw[5]}]

# user_sw:0
set_property LOC A13 [get_ports {user_sw[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_sw[6]}]
set_property PULLTYPE PULLUP [get_ports {user_sw[6]}]

# user_sw:0
set_property LOC A14 [get_ports {user_sw[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_sw[7]}]
set_property PULLTYPE PULLUP [get_ports {user_sw[7]}]

# lcd:0.rst
set_property LOC R6 [get_ports {lcd_rst}]
set_property IOSTANDARD LVCMOS33 [get_ports {lcd_rst}]

# lcd:0.dc
set_property LOC U4 [get_ports {lcd_dc}]
set_property IOSTANDARD LVCMOS33 [get_ports {lcd_dc}]

# lcd:0.copi
set_property LOC R3 [get_ports {lcd_copi}]
set_property IOSTANDARD LVCMOS33 [get_ports {lcd_copi}]

# lcd:0.clk
set_property LOC R5 [get_ports {lcd_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {lcd_clk}]

# lcd:0.cs
set_property LOC P5 [get_ports {lcd_cs}]
set_property IOSTANDARD LVCMOS33 [get_ports {lcd_cs}]

# lcd:0.backlight
set_property LOC N5 [get_ports {lcd_backlight}]
set_property IOSTANDARD LVCMOS33 [get_ports {lcd_backlight}]

# user_led:0
set_property LOC B13 [get_ports {user_led0}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led0}]

# user_led:1
set_property LOC B14 [get_ports {user_led1}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led1}]

# user_led:2
set_property LOC C12 [get_ports {user_led2}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led2}]

# user_led:3
set_property LOC B12 [get_ports {user_led3}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led3}]

# user_led:4
set_property LOC B11 [get_ports {user_led4}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led4}]

# user_led:5
set_property LOC A11 [get_ports {user_led5}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led5}]

# user_led:6
set_property LOC F13 [get_ports {user_led6}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led6}]

# user_led:7
set_property LOC F14 [get_ports {user_led7}]
set_property IOSTANDARD LVCMOS33 [get_ports {user_led7}]

################################################################################
# Design constraints
################################################################################

################################################################################
# Clock constraints
################################################################################


################################################################################
# False path constraints
################################################################################


set_false_path -quiet -to [get_cells -hierarchical -filter {mr_ff == TRUE}]

set_false_path -quiet -to [get_pins -filter {REF_PIN_NAME == PRE} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE || ars_ff2 == TRUE}]]

set_max_delay 2 -quiet -from [get_pins -filter {REF_PIN_NAME == C} -of_objects [get_cells -hierarchical -filter {ars_ff1 == TRUE}]] -to [get_pins -filter {REF_PIN_NAME == D} -of_objects [get_cells -hierarchical -filter {ars_ff2 == TRUE}]]