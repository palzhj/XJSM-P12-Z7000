# 12 JTAG groups (TCK/TMS/TDI/TDO) -> AX7Z020B expansion header J20/J21
# Per AX7Z020B board user manual V1.0, section 2.17 (tables 2.17.1 / 2.17.2)
# BANK34/35, VCCO defaults to 3.3 V (J21 is in BANK35 and can be changed to 2.5/1.8 V by a baseboard jumper)

# ---- group 1 (J20) ----
set_property PACKAGE_PIN R14  [get_ports jtag1_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag1_tck]
set_property PACKAGE_PIN P14  [get_ports jtag1_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag1_tms]
set_property PACKAGE_PIN U12  [get_ports jtag1_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag1_tdi]
set_property PACKAGE_PIN T12  [get_ports jtag1_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag1_tdo]

# ---- group 2 (J20) ----
set_property PACKAGE_PIN T15  [get_ports jtag2_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag2_tck]
set_property PACKAGE_PIN T14  [get_ports jtag2_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag2_tms]
set_property PACKAGE_PIN T11  [get_ports jtag2_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag2_tdi]
set_property PACKAGE_PIN T10  [get_ports jtag2_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag2_tdo]

# ---- group 3 (J20) ----
set_property PACKAGE_PIN U15  [get_ports jtag3_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag3_tck]
set_property PACKAGE_PIN U14  [get_ports jtag3_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag3_tms]
set_property PACKAGE_PIN P19  [get_ports jtag3_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag3_tdi]
set_property PACKAGE_PIN N18  [get_ports jtag3_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag3_tdo]

# ---- group 4 (J20) ----
set_property PACKAGE_PIN R17  [get_ports jtag4_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag4_tck]
set_property PACKAGE_PIN R16  [get_ports jtag4_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag4_tms]
set_property PACKAGE_PIN P15  [get_ports jtag4_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag4_tdi]
set_property PACKAGE_PIN P16  [get_ports jtag4_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag4_tdo]

# ---- group 5 (J20) ----
set_property PACKAGE_PIN N17  [get_ports jtag5_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag5_tck]
set_property PACKAGE_PIN P18  [get_ports jtag5_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag5_tms]
set_property PACKAGE_PIN V16  [get_ports jtag5_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag5_tdi]
set_property PACKAGE_PIN W16  [get_ports jtag5_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag5_tdo]

# ---- group 6 (J20) ----
set_property PACKAGE_PIN R18  [get_ports jtag6_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag6_tck]
set_property PACKAGE_PIN T17  [get_ports jtag6_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag6_tms]
set_property PACKAGE_PIN W19  [get_ports jtag6_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag6_tdi]
set_property PACKAGE_PIN W18  [get_ports jtag6_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag6_tdo]

# ---- group 7 (J21) ----
set_property PACKAGE_PIN M18  [get_ports jtag7_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag7_tck]
set_property PACKAGE_PIN M17  [get_ports jtag7_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag7_tms]
set_property PACKAGE_PIN K19  [get_ports jtag7_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag7_tdi]
set_property PACKAGE_PIN J19  [get_ports jtag7_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag7_tdo]

# ---- group 8 (J21) ----
set_property PACKAGE_PIN B19  [get_ports jtag8_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag8_tck]
set_property PACKAGE_PIN A20  [get_ports jtag8_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag8_tms]
set_property PACKAGE_PIN B20  [get_ports jtag8_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag8_tdi]
set_property PACKAGE_PIN C20  [get_ports jtag8_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag8_tdo]

# ---- group 9 (J21) ----
set_property PACKAGE_PIN G19  [get_ports jtag9_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag9_tck]
set_property PACKAGE_PIN G20  [get_ports jtag9_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag9_tms]
set_property PACKAGE_PIN M19  [get_ports jtag9_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag9_tdi]
set_property PACKAGE_PIN M20  [get_ports jtag9_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag9_tdo]

# ---- group 10 (J21) ----
set_property PACKAGE_PIN D20  [get_ports jtag10_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag10_tck]
set_property PACKAGE_PIN D19  [get_ports jtag10_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag10_tms]
set_property PACKAGE_PIN L20  [get_ports jtag10_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag10_tdi]
set_property PACKAGE_PIN L19  [get_ports jtag10_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag10_tdo]

# ---- group 11 (J21) ----
set_property PACKAGE_PIN F16  [get_ports jtag11_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag11_tck]
set_property PACKAGE_PIN F17  [get_ports jtag11_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag11_tms]
set_property PACKAGE_PIN H20  [get_ports jtag11_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag11_tdi]
set_property PACKAGE_PIN J20  [get_ports jtag11_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag11_tdo]

# ---- group 12 (J21) ----
set_property PACKAGE_PIN G18  [get_ports jtag12_tck]
set_property IOSTANDARD LVCMOS33 [get_ports jtag12_tck]
set_property PACKAGE_PIN G17  [get_ports jtag12_tms]
set_property IOSTANDARD LVCMOS33 [get_ports jtag12_tms]
set_property PACKAGE_PIN H17  [get_ports jtag12_tdi]
set_property IOSTANDARD LVCMOS33 [get_ports jtag12_tdi]
set_property PACKAGE_PIN H16  [get_ports jtag12_tdo]
set_property IOSTANDARD LVCMOS33 [get_ports jtag12_tdo]


# ---------------------------------------------------------------------------
# Default levels when no slave is attached (keeps TDO from floating and the target-side TAP in a defined state)
#   TMS/TDI/TCK are high-Z before configuration completes; weak pull-up/pull-down gives a defined level;
#   TDO is an input and floats when no slave is attached; a weak pull-up avoids noise.
# Once a slave is attached these weak pulls do not affect normal operation.
# ---------------------------------------------------------------------------


set_property PULLUP   true [get_ports {jtag*_tms}]
set_property PULLUP   true [get_ports {jtag*_tdi}]

set_property PULLDOWN true [get_ports {jtag*_tck}]
set_property PULLUP   true [get_ports {jtag*_tdo}]

# ---------------------------------------------------------------------------
# TDO input delay (fixes TIMING-18)
#
#   jtag*_tdo is driven by an external JTAG target board; the tool needs to know its arrival time
#   relative to clk_fpga_0 to analyze setup/hold on the input paths. The original constraints only
#   defined PACKAGE_PIN + IOSTANDARD without set_input_delay, so Vivado report_methodology reported 48 TIMING-18.
#
#   Basis for these values:
#     - TCK period 10 ns (100 MHz, DIV=5)
#     - board-to-board trace + target device TDO output delay totals < 5 ns
#     - the engine samples at ph_samp (~3/4 period = 7.5 ns), leaving > 4 ns of actual margin
#
#   -max 5.000 : setup check T - 5.0 - Tsu > 0  (10 - 5 - 0.5 = 4.5 ns margin)
#   -min 1.000 : hold  check 1.0 + Th  > 0
#
#   If TCK is raised to 20 MHz (5 ns period) in the future, tighten -max to 2.500.
# ---------------------------------------------------------------------------
set_input_delay -clock clk_fpga_0 -max 5.000 [get_ports {jtag*_tdo}]
set_input_delay -clock clk_fpga_0 -min 1.000 [get_ports {jtag*_tdo}]

# ---------------------------------------------------------------------------
# TCK/TMS/TDI output delay (fixes the remaining TIMING-18)
#
#   These three groups are outputs and likewise need set_output_delay for output path analysis.
#   36 entries = 12 channels x 3 signals.
#
#   Values match the input side (external trace + target device setup/hold requirement < 5 ns):
#     -max 5.000 : setup requirement of the external receiver
#     -min 1.000 : hold requirement of the external receiver
# ---------------------------------------------------------------------------
# Output data rate = clk_fpga_0 / (2*DIV) = 100MHz/10 = 10 MHz (100 ns per bit)
# so these outputs are 10-clock-cycle multicycle paths, not single-cycle.
set_output_delay -clock clk_fpga_0 -max 5.000 [get_ports {jtag*_tck}]
set_output_delay -clock clk_fpga_0 -min 1.000 [get_ports {jtag*_tck}]
set_output_delay -clock clk_fpga_0 -max 5.000 [get_ports {jtag*_tms}]
set_output_delay -clock clk_fpga_0 -min 1.000 [get_ports {jtag*_tms}]
set_output_delay -clock clk_fpga_0 -max 5.000 [get_ports {jtag*_tdi}]
set_output_delay -clock clk_fpga_0 -min 1.000 [get_ports {jtag*_tdi}]

# Each JTAG bit spans 2*DIV = 10 clk_fpga_0 cycles (DIV=5), constrained as multicycle
set_multicycle_path 10 -setup -to [get_ports {jtag*_tck}]
set_multicycle_path  9 -hold  -to [get_ports {jtag*_tck}]
set_multicycle_path 10 -setup -to [get_ports {jtag*_tms}]
set_multicycle_path  9 -hold  -to [get_ports {jtag*_tms}]
set_multicycle_path 10 -setup -to [get_ports {jtag*_tdi}]
set_multicycle_path  9 -hold  -to [get_ports {jtag*_tdi}]
