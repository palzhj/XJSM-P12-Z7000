# build.tcl - single-channel JTAG controller, XAPP1251 register path only.
#
#   cd single/reg && vivado -mode batch -source build.tcl
#
# Implements exactly XAPP1251 Table 1: LENGTH / TMS_VECTOR / TDI_VECTOR /
# TDO_VECTOR / CTRL. No FIFO, no DIV register, no STATUS, no DMA - the TCK
# rate is a build-time parameter (TCK_DIV), as it is a packaging option in the
# app note's IP.
#
# Self-contained: RTL in ./src, PS7 config in ./tcl, pins in ./g1.xdc.
# Outputs land in ./out, the Vivado project in ./work.

set here [file dirname [file normalize [info script]]]
set part   xc7z020clg400-2
set name   single_reg
set out_dir [file join $here out]
set proj    [file join $here work]

file mkdir $out_dir
create_project -force $name $proj -part $part

add_files -norecurse [file join $here src jtag_xapp1251.v]
add_files -fileset constrs_1 -norecurse [file join $here g1.xdc]

create_bd_design "system"

# ---- PS7 ----
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
source [file join $here tcl ps7_config.tcl]
apply_ps7_config [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst/ext_reset_in]
# HP0 is enabled in the PS7 config whether or not anything uses it
catch { connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/S_AXI_HP0_ACLK] }

# ---- one AXI4-Lite slave ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] [get_bd_cells axi]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi/S00_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/M00_ACLK]
connect_bd_net [get_bd_pins rst/interconnect_aresetn] [get_bd_pins axi/ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/S00_ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/M00_ARESETN]

# ---- the controller: XAPP1251 Table 1, TCK fixed at 100/(2*5) = 10 MHz ----
create_bd_cell -type module -reference jtag_xapp1251 jtag0
set_property -dict [list CONFIG.TCK_DIV 5] [get_bd_cells jtag0]
connect_bd_intf_net [get_bd_intf_pins jtag0/S_AXI] [get_bd_intf_pins axi/M00_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins jtag0/clk]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins jtag0/rstn]

# ---- pins: one G1 port ----
create_bd_port -dir O jtag_tck
create_bd_port -dir O jtag_tms
create_bd_port -dir O jtag_tdi
create_bd_port -dir I jtag_tdo
connect_bd_net [get_bd_pins jtag0/tck] [get_bd_ports jtag_tck]
connect_bd_net [get_bd_pins jtag0/tms] [get_bd_ports jtag_tms]
connect_bd_net [get_bd_pins jtag0/tdi] [get_bd_ports jtag_tdi]
connect_bd_net [get_bd_ports jtag_tdo] [get_bd_pins jtag0/tdo]

# ---- address map ----
set seg [get_bd_addr_segs jtag0/s_axi/reg0]
catch { set_property range 64K $seg }
assign_bd_address -offset 0x43C00000 -range 64K -target_address_space /ps7/Data $seg

save_bd_design
validate_bd_design
generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file join $proj ${name}.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
write_hw_platform -fixed -include_bit -force [file join $out_dir system.xsa]
file copy -force [file join $proj ${name}.runs impl_1 system_wrapper.bit] [file join $out_dir system_wrapper.bit]
puts "BUILD_DONE $name [file join $out_dir system_wrapper.bit]"
