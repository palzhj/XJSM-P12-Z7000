# G1 on J20 via AXI GPIO: bit0=TCK R14, bit1=TMS P14, bit2=TDI U12, TDO=T12
set_property PACKAGE_PIN R14 [get_ports {jtag_out[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {jtag_out[0]}]
set_property PACKAGE_PIN P14 [get_ports {jtag_out[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {jtag_out[1]}]
set_property PACKAGE_PIN U12 [get_ports {jtag_out[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {jtag_out[2]}]
set_property PACKAGE_PIN T12 [get_ports jtag_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdo]

set_property PULLUP   true [get_ports {jtag_out[1]}]
set_property PULLUP   true [get_ports {jtag_out[2]}]
set_property PULLDOWN true [get_ports {jtag_out[0]}]
set_property PULLUP   true [get_ports jtag_tdo]
