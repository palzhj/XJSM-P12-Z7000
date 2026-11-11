# build_jtag12.tcl — 12-channel XVC (single engine + channel select)
# Address: 0x43C00000; the CHSEL register at 0x3C selects G1..G12
set script_dir [file dirname [file normalize [info script]]]
set out_dir    [file join $script_dir out_jtag12]
set proj       [file join $script_dir work_jtag12]
file mkdir $out_dir
create_project -force jtag12 $proj -part xc7z020clg400-2
set_property target_language Verilog [current_project]

add_files -norecurse [list \
    [file join $script_dir rtl jtag_ctrl.v] \
    [file join $script_dir rtl jtag12_mux.v] ]
update_compile_order -fileset sources_1

create_bd_design "system"
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
source [file join $script_dir tcl ps7_config.tcl]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst/ext_reset_in]

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] [get_bd_cells axi]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi/S00_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/M00_ACLK]
connect_bd_net [get_bd_pins rst/interconnect_aresetn] [get_bd_pins axi/ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/S00_ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/M00_ARESETN]

create_bd_cell -type module -reference jtag_ctrl jtag
connect_bd_intf_net [get_bd_intf_pins jtag/S_AXI] [get_bd_intf_pins axi/M00_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins jtag/clk]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins jtag/rstn]

create_bd_cell -type module -reference jtag12_mux jmux
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins jmux/clk]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins jmux/rstn]
connect_bd_net [get_bd_pins jtag/tck]  [get_bd_pins jmux/tck_i]
connect_bd_net [get_bd_pins jtag/tms]  [get_bd_pins jmux/tms_i]
connect_bd_net [get_bd_pins jtag/tdi]  [get_bd_pins jmux/tdi_i]
connect_bd_net [get_bd_pins jmux/tdo_o] [get_bd_pins jtag/tdo]
connect_bd_net [get_bd_pins jtag/chsel] [get_bd_pins jmux/chsel]

create_bd_port -dir O jtag1_tck
create_bd_port -dir O jtag1_tms
create_bd_port -dir O jtag1_tdi
create_bd_port -dir I jtag1_tdo
create_bd_port -dir O jtag2_tck
create_bd_port -dir O jtag2_tms
create_bd_port -dir O jtag2_tdi
create_bd_port -dir I jtag2_tdo
create_bd_port -dir O jtag3_tck
create_bd_port -dir O jtag3_tms
create_bd_port -dir O jtag3_tdi
create_bd_port -dir I jtag3_tdo
create_bd_port -dir O jtag4_tck
create_bd_port -dir O jtag4_tms
create_bd_port -dir O jtag4_tdi
create_bd_port -dir I jtag4_tdo
create_bd_port -dir O jtag5_tck
create_bd_port -dir O jtag5_tms
create_bd_port -dir O jtag5_tdi
create_bd_port -dir I jtag5_tdo
create_bd_port -dir O jtag6_tck
create_bd_port -dir O jtag6_tms
create_bd_port -dir O jtag6_tdi
create_bd_port -dir I jtag6_tdo
create_bd_port -dir O jtag7_tck
create_bd_port -dir O jtag7_tms
create_bd_port -dir O jtag7_tdi
create_bd_port -dir I jtag7_tdo
create_bd_port -dir O jtag8_tck
create_bd_port -dir O jtag8_tms
create_bd_port -dir O jtag8_tdi
create_bd_port -dir I jtag8_tdo
create_bd_port -dir O jtag9_tck
create_bd_port -dir O jtag9_tms
create_bd_port -dir O jtag9_tdi
create_bd_port -dir I jtag9_tdo
create_bd_port -dir O jtag10_tck
create_bd_port -dir O jtag10_tms
create_bd_port -dir O jtag10_tdi
create_bd_port -dir I jtag10_tdo
create_bd_port -dir O jtag11_tck
create_bd_port -dir O jtag11_tms
create_bd_port -dir O jtag11_tdi
create_bd_port -dir I jtag11_tdo
create_bd_port -dir O jtag12_tck
create_bd_port -dir O jtag12_tms
create_bd_port -dir O jtag12_tdi
create_bd_port -dir I jtag12_tdo
connect_bd_net [get_bd_pins jmux/jtag1_tck] [get_bd_ports jtag1_tck]
connect_bd_net [get_bd_pins jmux/jtag1_tms] [get_bd_ports jtag1_tms]
connect_bd_net [get_bd_pins jmux/jtag1_tdi] [get_bd_ports jtag1_tdi]
connect_bd_net [get_bd_pins jmux/jtag1_tdo] [get_bd_ports jtag1_tdo]
connect_bd_net [get_bd_pins jmux/jtag2_tck] [get_bd_ports jtag2_tck]
connect_bd_net [get_bd_pins jmux/jtag2_tms] [get_bd_ports jtag2_tms]
connect_bd_net [get_bd_pins jmux/jtag2_tdi] [get_bd_ports jtag2_tdi]
connect_bd_net [get_bd_pins jmux/jtag2_tdo] [get_bd_ports jtag2_tdo]
connect_bd_net [get_bd_pins jmux/jtag3_tck] [get_bd_ports jtag3_tck]
connect_bd_net [get_bd_pins jmux/jtag3_tms] [get_bd_ports jtag3_tms]
connect_bd_net [get_bd_pins jmux/jtag3_tdi] [get_bd_ports jtag3_tdi]
connect_bd_net [get_bd_pins jmux/jtag3_tdo] [get_bd_ports jtag3_tdo]
connect_bd_net [get_bd_pins jmux/jtag4_tck] [get_bd_ports jtag4_tck]
connect_bd_net [get_bd_pins jmux/jtag4_tms] [get_bd_ports jtag4_tms]
connect_bd_net [get_bd_pins jmux/jtag4_tdi] [get_bd_ports jtag4_tdi]
connect_bd_net [get_bd_pins jmux/jtag4_tdo] [get_bd_ports jtag4_tdo]
connect_bd_net [get_bd_pins jmux/jtag5_tck] [get_bd_ports jtag5_tck]
connect_bd_net [get_bd_pins jmux/jtag5_tms] [get_bd_ports jtag5_tms]
connect_bd_net [get_bd_pins jmux/jtag5_tdi] [get_bd_ports jtag5_tdi]
connect_bd_net [get_bd_pins jmux/jtag5_tdo] [get_bd_ports jtag5_tdo]
connect_bd_net [get_bd_pins jmux/jtag6_tck] [get_bd_ports jtag6_tck]
connect_bd_net [get_bd_pins jmux/jtag6_tms] [get_bd_ports jtag6_tms]
connect_bd_net [get_bd_pins jmux/jtag6_tdi] [get_bd_ports jtag6_tdi]
connect_bd_net [get_bd_pins jmux/jtag6_tdo] [get_bd_ports jtag6_tdo]
connect_bd_net [get_bd_pins jmux/jtag7_tck] [get_bd_ports jtag7_tck]
connect_bd_net [get_bd_pins jmux/jtag7_tms] [get_bd_ports jtag7_tms]
connect_bd_net [get_bd_pins jmux/jtag7_tdi] [get_bd_ports jtag7_tdi]
connect_bd_net [get_bd_pins jmux/jtag7_tdo] [get_bd_ports jtag7_tdo]
connect_bd_net [get_bd_pins jmux/jtag8_tck] [get_bd_ports jtag8_tck]
connect_bd_net [get_bd_pins jmux/jtag8_tms] [get_bd_ports jtag8_tms]
connect_bd_net [get_bd_pins jmux/jtag8_tdi] [get_bd_ports jtag8_tdi]
connect_bd_net [get_bd_pins jmux/jtag8_tdo] [get_bd_ports jtag8_tdo]
connect_bd_net [get_bd_pins jmux/jtag9_tck] [get_bd_ports jtag9_tck]
connect_bd_net [get_bd_pins jmux/jtag9_tms] [get_bd_ports jtag9_tms]
connect_bd_net [get_bd_pins jmux/jtag9_tdi] [get_bd_ports jtag9_tdi]
connect_bd_net [get_bd_pins jmux/jtag9_tdo] [get_bd_ports jtag9_tdo]
connect_bd_net [get_bd_pins jmux/jtag10_tck] [get_bd_ports jtag10_tck]
connect_bd_net [get_bd_pins jmux/jtag10_tms] [get_bd_ports jtag10_tms]
connect_bd_net [get_bd_pins jmux/jtag10_tdi] [get_bd_ports jtag10_tdi]
connect_bd_net [get_bd_pins jmux/jtag10_tdo] [get_bd_ports jtag10_tdo]
connect_bd_net [get_bd_pins jmux/jtag11_tck] [get_bd_ports jtag11_tck]
connect_bd_net [get_bd_pins jmux/jtag11_tms] [get_bd_ports jtag11_tms]
connect_bd_net [get_bd_pins jmux/jtag11_tdi] [get_bd_ports jtag11_tdi]
connect_bd_net [get_bd_pins jmux/jtag11_tdo] [get_bd_ports jtag11_tdo]
connect_bd_net [get_bd_pins jmux/jtag12_tck] [get_bd_ports jtag12_tck]
connect_bd_net [get_bd_pins jmux/jtag12_tms] [get_bd_ports jtag12_tms]
connect_bd_net [get_bd_pins jmux/jtag12_tdi] [get_bd_ports jtag12_tdi]
connect_bd_net [get_bd_pins jmux/jtag12_tdo] [get_bd_ports jtag12_tdo]
# ILA optional: observe group 1 of the 12 channels
assign_bd_address
save_bd_design
validate_bd_design
set bd_file [get_files system.bd]
generate_target all $bd_file
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file join $proj jtag12.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
read_xdc [file join $script_dir constraints jtag12.xdc]
set_property strategy Performance_Explore [get_runs impl_1]
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
write_bitstream -force [file join $out_dir system_wrapper.bit]
puts "BUILD_DONE"
