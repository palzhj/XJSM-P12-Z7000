# build_g1.tcl - minimal system: PS7 + AXI-Lite JTAG controller -> J20 G1 (per XAPP1251)
set script_dir [file dirname [file normalize [info script]]]
set out_dir    [file join $script_dir out_g1_oled2]
file mkdir $out_dir
set proj [file join $script_dir work_g1_oled2]
create_project -force -part xc7z020clg400-2 $proj

add_files -norecurse [file join $script_dir rtl jtag_ctrl.v]
add_files -norecurse [file join $script_dir rtl i2c_emio.v]
read_xdc [file join $script_dir constraints g1.xdc]
read_xdc [file join $script_dir constraints oled_i2c.xdc]

create_bd_design system
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
source [file join $script_dir tcl ps7_config.tcl]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_USE_S_AXI_HP0 {0}] [get_bd_cells ps7]
set_property -dict [list CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] [get_bd_cells ps7]
# OLED: PS7 I2C1 via EMIO (all three properties are required)
set_property -dict [list \
    CONFIG.PCW_EN_I2C1 {1} \
    CONFIG.PCW_EN_EMIO_I2C1 {1} \
    CONFIG.PCW_I2C1_I2C1_IO {EMIO}] [get_bd_cells ps7]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset rst
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] [get_bd_cells axi]

create_bd_cell -type module -reference jtag_ctrl jtag
set_property -dict [list CONFIG.ASSOCIATED_BUSIF {s_axi} CONFIG.ASSOCIATED_RESET {rstn}] [get_bd_pins jtag/clk]

connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst/ext_reset_in]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/S00_ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/M00_ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins jtag/rstn]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi/M00_AXI] [get_bd_intf_pins jtag/s_axi]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins jtag/clk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/M00_ACLK]

foreach p {tck tms tdi} {
  create_bd_port -dir O jtag_$p
  connect_bd_net [get_bd_pins jtag/$p] [get_bd_ports jtag_$p]
}
create_bd_port -dir I jtag_tdo
connect_bd_net [get_bd_pins jtag/tdo] [get_bd_ports jtag_tdo]

# --- ILA: four independent 1-bit probes (tck/tms/tdi/tdo) ---
create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 ila
set_property -dict [list CONFIG.C_MON_TYPE {NATIVE} \
    CONFIG.C_NUM_OF_PROBES {4} CONFIG.C_DATA_DEPTH {16384} \
    CONFIG.C_PROBE0_WIDTH {1} CONFIG.C_PROBE1_WIDTH {1} \
    CONFIG.C_PROBE2_WIDTH {1} CONFIG.C_PROBE3_WIDTH {1} \
    CONFIG.C_ADV_TRIGGER {false}] [get_bd_cells ila]
connect_bd_net [get_bd_pins jtag/tck]  [get_bd_pins ila/probe0]
connect_bd_net [get_bd_pins jtag/tms]  [get_bd_pins ila/probe1]
connect_bd_net [get_bd_pins jtag/tdi]  [get_bd_pins ila/probe2]
connect_bd_net [get_bd_pins jtag/tdo]  [get_bd_pins ila/probe3]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ila/clk]

# ---- OLED I2C: PS7 EMIO -> IOBUFs -> J20 pin35(V15)/pin33(U20) ----
create_bd_cell -type module -reference i2c_emio i2c_emio_0
create_bd_port -dir IO i2c_scl
create_bd_port -dir IO i2c_sda
connect_bd_net [get_bd_pins i2c_emio_0/i2c_scl] [get_bd_ports i2c_scl]
connect_bd_net [get_bd_pins i2c_emio_0/i2c_sda] [get_bd_ports i2c_sda]
connect_bd_net [get_bd_pins ps7/I2C1_SCL_I] [get_bd_pins i2c_emio_0/scl_i]
connect_bd_net [get_bd_pins ps7/I2C1_SCL_O] [get_bd_pins i2c_emio_0/scl_o]
connect_bd_net [get_bd_pins ps7/I2C1_SCL_T] [get_bd_pins i2c_emio_0/scl_t]
connect_bd_net [get_bd_pins ps7/I2C1_SDA_I] [get_bd_pins i2c_emio_0/sda_i]
connect_bd_net [get_bd_pins ps7/I2C1_SDA_O] [get_bd_pins i2c_emio_0/sda_o]
connect_bd_net [get_bd_pins ps7/I2C1_SDA_T] [get_bd_pins i2c_emio_0/sda_t]

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
puts "G1_BUILD_DONE"
