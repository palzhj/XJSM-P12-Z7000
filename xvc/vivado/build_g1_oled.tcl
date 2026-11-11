# build_g1_oled.tcl - G1 JTAG bit-bang + SSD1315 OLED I2C on J20
#
# Same as build_g1_gpio.tcl (PS7 + AXI-Lite JTAG controller on J20 pins 3-6)
# plus a second I2C master for the front-panel OLED:
#
#   PS7 I2C1 -> EMIO -> i2c_emio (IOBUFs) -> J20 pin 35 (V15) = SCL
#                                          -> J20 pin 33 (U20) = SDA
#
# I2C0 stays on MIO50/51 (the on-board EEPROM/RTC bus) so nothing that
# already works is disturbed.  Linux sees the OLED bus as /dev/i2c-1.
#
# Usage: vivado -mode batch -source build_g1_oled.tcl
set script_dir [file dirname [file normalize [info script]]]
set out_dir    [file join $script_dir out_g1_oled]
file mkdir $out_dir
set proj [file join $script_dir work_g1_oled]
create_project -force -part xc7z020clg400-2 $proj

read_xdc [file join $script_dir constraints g1_gpio.xdc]
read_xdc [file join $script_dir constraints oled_i2c.xdc]

# RTL for the EMIO tri-state buffers (needed before the BD module reference)
add_files -norecurse [file join $script_dir rtl i2c_emio.v]
update_compile_order -fileset sources_1

create_bd_design system
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
source [file join $script_dir tcl ps7_config.tcl]
set_property -dict [list CONFIG.PCW_USE_M_AXI_GP0 {1} CONFIG.PCW_USE_S_AXI_HP0 {0}] [get_bd_cells ps7]
set_property -dict [list CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100}] [get_bd_cells ps7]

# OLED: add a second I2C controller on EMIO, leave I2C0 (MIO50/51) alone.
# All three properties are required; setting only EN_EMIO_I2C1 leaves the
# controller unmapped and no I2C1_* pins appear on the PS7 cell.
set_property -dict [list \
    CONFIG.PCW_EN_I2C1 {1} \
    CONFIG.PCW_EN_EMIO_I2C1 {1} \
    CONFIG.PCW_I2C1_I2C1_IO {EMIO}] [get_bd_cells ps7]

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

# ---- OLED I2C: PS7 EMIO -> IOBUFs -> package pins -------------------------
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
puts "G1_OLED_BUILD_DONE"
