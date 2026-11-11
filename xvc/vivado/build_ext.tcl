# =============================================================================
# XVC remote-debug reference project for ALINX AC7Z020 (XC7Z020-2CLG400I)
#
# Architecture follows Xilinx KB "Designing an XVC project for Remote Debugging
# of Zynq UltraScale+ devices", adapted to Zynq-7000:
#
#   PS7 (M_AXI_GP0) -> AXI Interconnect -> Debug Bridge #1 (AXI to BSCAN,
#   JTAG fallback = internal BSCAN primitive) --m0_bscan--> Debug Bridge #2
#   (BSCAN to Debug Hub) -> System ILA (8-bit probe on binary counter)
#
# Usage:
#   vivado -mode batch -source build.tcl -tclargs bd|full
# =============================================================================

set script_dir [file dirname [file normalize [info script]]]
set proj_name  xvc_ext
set proj_dir   [file join $script_dir work_ext]
set part_name  xc7z020clg400-2

set stage "full"
if {[llength $argv] > 0} { set stage [lindex $argv 0] }

proc fail {msg} {
  puts "ERROR: $msg"
  exit 1
}

# ---------------------------------------------------------------- project ----
if {[file exists [file join $proj_dir ${proj_name}.xpr]]} {
  open_project [file join $proj_dir ${proj_name}.xpr]
} else {
  create_project $proj_name $proj_dir -part $part_name -force
}
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

# ------------------------------------------------------------- block design --
if {[llength [get_files -quiet system.bd]] == 0} {
  create_bd_design system
} else {
  open_bd_design [get_files system.bd]
}

set design [current_bd_design]
if {[llength [get_bd_cells -quiet ps7]] == 0} {

  # --- PS7 with the vendor configuration of the AC7Z020 carrier ------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
  source [file join $script_dir tcl ps7_config.tcl]
  apply_ps7_config [get_bd_cells ps7]
  set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
  ] [get_bd_cells ps7]
  make_bd_intf_pins_external  [get_bd_intf_pins ps7/DDR]
  make_bd_intf_pins_external  [get_bd_intf_pins ps7/FIXED_IO]

  # --- binary counter (the "design under debug") ----------------------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:c_counter_binary:12.0 counter
  set_property -dict [list \
    CONFIG.Output_Width {8} \
    CONFIG.Increment_Value {1} \
    CONFIG.CE {true} \
    CONFIG.SCLR {true} \
  ] [get_bd_cells counter]

  # --- system ILA: one 8-bit probe on the counter output --------------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 ila
  set_property -dict [list \
    CONFIG.C_MON_TYPE {NATIVE} \
    CONFIG.C_NUM_OF_PROBES {1} \
    CONFIG.C_PROBE_WIDTH_PROPAGATION {MANUAL} \
    CONFIG.C_PROBE0_WIDTH {8} \
    CONFIG.C_DATA_DEPTH {1024} \
  ] [get_bd_cells ila]

  # --- Debug Bridge #1: AXI -> BSCAN, JTAG fallback via internal BSCAN ------
  create_bd_cell -type ip -vlnv xilinx.com:ip:debug_bridge:3.0 dbg_axi2bscan
  set_property -dict [list \
    CONFIG.C_DEBUG_MODE {2} \
    CONFIG.C_BSCAN_MUX  {3} \
  ] [get_bd_cells dbg_axi2bscan]

  # --- external BSCAN primitive (mux=3 needs it) ----------------------------
  add_files -norecurse [file join $script_dir rtl bscan_tap.v]
  create_bd_cell -type module -reference bscan_tap bscan_prim
  foreach sig {tck tms tdi sel capture shift update drck reset runtest} {
    connect_bd_net [get_bd_pins bscan_prim/$sig] [get_bd_pins dbg_axi2bscan/prim_bscan_$sig]
  }
  connect_bd_net [get_bd_pins dbg_axi2bscan/prim_bscan_tdo] [get_bd_pins bscan_prim/tdo]
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_bscanid
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells const_bscanid]
  connect_bd_net [get_bd_pins const_bscanid/dout] [get_bd_pins dbg_axi2bscan/prim_bscan_bscanid_en]

  # --- Debug Bridge #2: BSCAN -> Debug Hub ---------------------------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:debug_bridge:3.0 dbg_bscan2hub
  set_property -dict [list CONFIG.C_DEBUG_MODE {1}] [get_bd_cells dbg_bscan2hub]

  # --- clock / reset --------------------------------------------------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_100m
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins rst_100m/slowest_sync_clk]
  connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_100m/ext_reset_in]

  # --- AXI interconnect -----------------------------------------------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ps7_0_axi_periph
  set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {1}] [get_bd_cells ps7_0_axi_periph]

  # --- connections ----------------------------------------------------------
  connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0]              [get_bd_intf_pins ps7_0_axi_periph/S00_AXI]
  connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M00_AXI]   [get_bd_intf_pins dbg_axi2bscan/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins dbg_axi2bscan/m0_bscan]     [get_bd_intf_pins dbg_bscan2hub/S_BSCAN]

  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7_0_axi_periph/ACLK]
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7_0_axi_periph/S00_ACLK]
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7_0_axi_periph/M00_ACLK]
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins dbg_axi2bscan/s_axi_aclk]
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins dbg_bscan2hub/clk]
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins counter/clk]
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ila/clk]

  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins ps7_0_axi_periph/ARESETN]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins ps7_0_axi_periph/S00_ARESETN]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins ps7_0_axi_periph/M00_ARESETN]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins dbg_axi2bscan/s_axi_aresetn]

  # counter always enabled, load disabled
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells const_one]
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells const_zero]

  connect_bd_net [get_bd_pins const_one/dout]  [get_bd_pins counter/CE]
  connect_bd_net [get_bd_pins const_zero/dout] [get_bd_pins counter/SCLR]

  foreach p {counter/Q} {
    connect_bd_net [get_bd_pins $p] [get_bd_pins ila/probe0]
  }

  # --- addressing -----------------------------------------------------------
  assign_bd_address -quiet [get_bd_addr_segs -of_objects [get_bd_cells dbg_axi2bscan]]

  regenerate_bd_layout
  validate_bd_design
  save_bd_design
}

# ----------------------------------------------------------------- wrapper ---
if {[llength [get_files -quiet system_wrapper.v]] == 0} {
  set wrapper [make_wrapper -files [get_files system.bd] -top -force]
  add_files -norecurse $wrapper
}
set_property top system_wrapper [current_fileset]

# -------------------------------------------------------------- constraints --
set xdc [file join $script_dir constraints xvc.xdc]
if {[file exists $xdc]} {
  add_files -fileset constrs_1 -norecurse $xdc
}

if {$stage eq "bd"} {
  puts "BD_ONLY_DONE"
  exit 0
}

# ------------------------------------------------------------ build (synth) --
if {$stage eq "synth"} {
  reset_run synth_1
  launch_runs synth_1 -jobs 8
  wait_on_run synth_1
  if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { fail "synthesis failed" }
  puts "SYNTH_DONE"
  exit 0
}

# ------------------------------------------------------- full build flow -----
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { fail "implementation failed" }

# ------------------------------------------------------------------ export ---
file mkdir [file join $script_dir out_ext]
open_run impl_1
write_debug_probes -force [file join $script_dir out_ext system.ltx]
write_hw_platform -fixed -include_bit -force [file join $script_dir out_ext system.xsa]
puts "XSA_WRITTEN [file join $script_dir out_ext system.xsa]"
puts "FULL_BUILD_DONE"
