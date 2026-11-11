# G1 on J20: R14=TCK, P14=TMS, U12=TDI, T12=TDO
set_property PACKAGE_PIN R14 [get_ports jtag_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tck]
set_property PACKAGE_PIN P14 [get_ports jtag_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tms]
set_property PACKAGE_PIN U12 [get_ports jtag_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdi]
set_property PACKAGE_PIN T12 [get_ports jtag_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdo]

set_property PULLUP   true [get_ports jtag_tms]
set_property PULLUP   true [get_ports jtag_tdi]
set_property PULLDOWN true [get_ports jtag_tck]
set_property PULLUP   true [get_ports jtag_tdo]

