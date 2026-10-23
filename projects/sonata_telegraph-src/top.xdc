# lowRISC Sonata (Artix-7 XC7A50T-CSG324); pins from sonata-system data/pins_sonata.xdc
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports mainClk]
create_clock -period 40.000 -name mainClk [get_ports mainClk]

# PCB revision 0.3 and above (R11 on 0.2 and below)
set_property -dict { PACKAGE_PIN T5 IOSTANDARD LVCMOS33 } [get_ports nrst]

set_property -dict { PACKAGE_PIN C17 IOSTANDARD LVCMOS33 } [get_ports ser0_tx]
set_property -dict { PACKAGE_PIN B13 IOSTANDARD LVCMOS33 } [get_ports {usrLed[0]}]
set_property -dict { PACKAGE_PIN B14 IOSTANDARD LVCMOS33 } [get_ports {usrLed[1]}]
set_property -dict { PACKAGE_PIN C12 IOSTANDARD LVCMOS33 } [get_ports {usrLed[2]}]
set_property -dict { PACKAGE_PIN B12 IOSTANDARD LVCMOS33 } [get_ports {usrLed[3]}]
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports {usrLed[4]}]
set_property -dict { PACKAGE_PIN A11 IOSTANDARD LVCMOS33 } [get_ports {usrLed[5]}]
set_property -dict { PACKAGE_PIN F13 IOSTANDARD LVCMOS33 } [get_ports {usrLed[6]}]
set_property -dict { PACKAGE_PIN F14 IOSTANDARD LVCMOS33 } [get_ports {usrLed[7]}]
