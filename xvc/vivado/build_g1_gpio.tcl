# build_g1.tcl - minimal system: PS7 + AXI-Lite JTAG controller -> J20 G1 (per XAPP1251)
set script_dir [file dirname [file normalize [info script]]]
set out_dir    [file join $script_dir out_g1]
file mkdir $out_dir
set proj [file join $script_dir work_g1]
create_project -force -part xc7z020clg400-2 $proj

# GPIO variant: no RTL needed
read_xdc [file join $script_dir constraints g1_gpio.xdc]

create_bd_design system
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
source [file join $script_dir tcl ps7_config.tcl]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_USE_S_AXI_HP0 {0}] [get_bd_cells ps7]
set_property -dict [list CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] [get_bd_cells ps7]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] [get_bd_cells axi]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio jtag
set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {3} CONFIG.C_GPIO2_WIDTH {1} CONFIG.C_IS_DUAL {1} \
    CONFIG.C_ALL_OUTPUTS {1} CONFIG.C_ALL_INPUTS_2 {1} \
    CONFIG.C_DOUT_DEFAULT {0x0} CONFIG.C_TRI_DEFAULT {0x0}] [get_bd_cells jtag]

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst/ext_reset_in]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/S00_ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/M00_ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins jtag/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi/M00_AXI] [get_bd_intf_pins jtag/S_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins jtag/s_axi_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/M00_ACLK]

create_bd_port -dir O -from 2 -to 0 jtag_out
connect_bd_net [get_bd_pins jtag/gpio_io_o] [get_bd_ports jtag_out]
create_bd_port -dir I jtag_tdo
connect_bd_net [get_bd_pins jtag/gpio2_io_i] [get_bd_ports jtag_tdo]

assign_bd_address -quiet [get_bd_addr_segs -of_objects [get_bd_cells jtag]]
set segs [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]]
foreach seg $segs {
  if {[string match *jtag* $seg]} {
    catch { set_property range 64K $seg }
    catch { set_property offset 0x43C00000 $seg }
    puts "ADDR $seg -> offset=[get_property offset $seg] range=[get_property range $seg]"
  }
}
regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files system.bd] -top -force
add_files -norecurse [glob $proj.gen/sources_1/bd/system/hdl/system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
write_debug_probes -force [file join $out_dir system.ltx]
write_hwdef -force -file [file join $out_dir system.hwdef]
write_bitstream -force [file join $out_dir system_wrapper.bit]
write_hw_platform -fixed -include_bit -force -file [file join $out_dir system.xsa]
puts "G1_GPIO_BUILD_DONE"
