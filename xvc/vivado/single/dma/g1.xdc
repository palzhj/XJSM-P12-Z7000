# g1_single.xdc - one JTAG channel on the J20 G1 connector.
#
# R14=TCK  P14=TMS  U12=TDI  T12=TDO   (AX7Z020B manual, section 2.17)
#
# Same electrical treatment as jtag12.xdc, but for a single port. Note: no
# foreach loops here - Vivado does not support them in XDC.

set_property PACKAGE_PIN R14 [get_ports jtag_tck]
set_property PACKAGE_PIN P14 [get_ports jtag_tms]
set_property PACKAGE_PIN U12 [get_ports jtag_tdi]
set_property PACKAGE_PIN T12 [get_ports jtag_tdo]

set_property IOSTANDARD LVCMOS33 [get_ports jtag_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag_tdo]

# Defined levels when no slave is attached
set_property PULLUP   true [get_ports jtag_tms]
set_property PULLUP   true [get_ports jtag_tdi]
set_property PULLDOWN true [get_ports jtag_tck]
set_property PULLUP   true [get_ports jtag_tdo]

# TDO arrives from the target board; bound its arrival window (TIMING-18).
set_input_delay -clock clk_fpga_0 -max 5.000 [get_ports jtag_tdo]
set_input_delay -clock clk_fpga_0 -min 1.000 [get_ports jtag_tdo]

# TCK/TMS/TDI go to the target: one bit spans 2*DIV = 10 clocks at DIV=5,
# so these are multicycle paths, not single-cycle ones.
set_output_delay -clock clk_fpga_0 -max 5.000 [get_ports jtag_tck]
set_output_delay -clock clk_fpga_0 -min 1.000 [get_ports jtag_tck]
set_output_delay -clock clk_fpga_0 -max 5.000 [get_ports jtag_tms]
set_output_delay -clock clk_fpga_0 -min 1.000 [get_ports jtag_tms]
set_output_delay -clock clk_fpga_0 -max 5.000 [get_ports jtag_tdi]
set_output_delay -clock clk_fpga_0 -min 1.000 [get_ports jtag_tdi]

set_multicycle_path 10 -setup -to [get_ports jtag_tck]
set_multicycle_path  9 -hold  -to [get_ports jtag_tck]
set_multicycle_path 10 -setup -to [get_ports jtag_tms]
set_multicycle_path  9 -hold  -to [get_ports jtag_tms]
set_multicycle_path 10 -setup -to [get_ports jtag_tdi]
set_multicycle_path  9 -hold  -to [get_ports jtag_tdi]
