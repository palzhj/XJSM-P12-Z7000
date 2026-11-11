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
set proj_name  xvc
set proj_dir   [file join $script_dir work]
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

# --- 12 JTAG port groups (J20/J21 expansion header, see docs/JTAG12_J20_J21.md) ----------
set jtag_rtl  [file join $script_dir rtl jtag12_io.v]
set jtagm_rtl [file join $script_dir rtl jtag_master.v]
foreach f [list $jtag_rtl $jtagm_rtl] {
  if {[file exists $f] && [llength [get_files -quiet [file tail $f]]] == 0} {
    add_files -norecurse $f
  }
}
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
    CONFIG.C_PROBE0_WIDTH {12} \
    CONFIG.C_DATA_DEPTH {1024} \
  ] [get_bd_cells ila]

  # --- Debug Bridge #1: AXI -> BSCAN, JTAG fallback via internal BSCAN ------
  create_bd_cell -type ip -vlnv xilinx.com:ip:debug_bridge:3.0 dbg_axi2bscan
  set_property -dict [list \
    CONFIG.C_DEBUG_MODE {2} \
    CONFIG.C_BSCAN_MUX  {2} \
  ] [get_bd_cells dbg_axi2bscan]

  # --- Debug Bridge #2: BSCAN -> Debug Hub ---------------------------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:debug_bridge:3.0 dbg_bscan2hub
  set_property -dict [list CONFIG.C_DEBUG_MODE {1}] [get_bd_cells dbg_bscan2hub]

  # --- clock / reset --------------------------------------------------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_100m
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0]     [get_bd_pins rst_100m/slowest_sync_clk]
  connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst_100m/ext_reset_in]

  # --- AXI interconnect -----------------------------------------------------
  create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 ps7_0_axi_periph
  set_property -dict [list CONFIG.NUM_MI {2} CONFIG.NUM_SI {1}] [get_bd_cells ps7_0_axi_periph]

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
  connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7_0_axi_periph/M01_ACLK]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins ps7_0_axi_periph/M01_ARESETN]
  connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins dbg_axi2bscan/s_axi_aresetn]

  # counter always enabled, load disabled
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells const_one]
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells const_zero]

  connect_bd_net [get_bd_pins const_one/dout]  [get_bd_pins counter/CE]
  connect_bd_net [get_bd_pins const_zero/dout] [get_bd_pins counter/SCLR]

  # probe0 = {tdo, tdi, tms, tck, counter[7:0]}  (bit11..8 = JTAG, bit7..0 = counter)
  create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 ila_concat
  set_property -dict [list CONFIG.NUM_PORTS {5} \
      CONFIG.IN0_WIDTH {8} CONFIG.IN1_WIDTH {1} CONFIG.IN2_WIDTH {1} \
      CONFIG.IN3_WIDTH {1} CONFIG.IN4_WIDTH {1}] [get_bd_cells ila_concat]
  connect_bd_net [get_bd_pins counter/Q]     [get_bd_pins ila_concat/In0]
  connect_bd_net [get_bd_pins ila_concat/dout] [get_bd_pins ila/probe0]

  # --- 12 JTAG IO groups (J20/J21) ---------------------------------------------
  if {[file exists $jtag_rtl]} {
    create_bd_cell -type module -reference jtag12_io jtag12
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins jtag12/clk]
    for {set g 2} {$g <= 12} {incr g} {
      foreach sig {tck tms tdi} {
        set p jtag${g}_${sig}
        create_bd_port -dir O $p
        connect_bd_net [get_bd_pins jtag12/$p] [get_bd_ports $p]
      }
      set p jtag${g}_tdo
      create_bd_port -dir I $p
      connect_bd_net [get_bd_pins jtag12/$p] [get_bd_ports $p]
    }
  }

  # --- G1: AXI-Lite -> hardware TAP engine (jtag_master) --------------------------
  if {[file exists $jtagm_rtl]} {
    create_bd_cell -type module -reference jtag_master jtagm
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins jtagm/clk]
    connect_bd_net [get_bd_pins rst_100m/peripheral_aresetn] [get_bd_pins jtagm/rstn]
    set_property -dict [list CONFIG.ASSOCIATED_BUSIF {s_axi} \
                             CONFIG.ASSOCIATED_RESET {rstn}] [get_bd_pins jtagm/clk]
    connect_bd_intf_net [get_bd_intf_pins ps7_0_axi_periph/M01_AXI] [get_bd_intf_pins jtagm/s_axi]
    foreach sig {tck tms tdi} {
      set p jtag1_${sig}
      create_bd_port -dir O $p
      connect_bd_net [get_bd_pins jtagm/$sig] [get_bd_ports $p]
    }
    create_bd_port -dir I jtag1_tdo
    connect_bd_net [get_bd_pins jtagm/tdo] [get_bd_ports jtag1_tdo]
    if {[llength [get_bd_cells -quiet ila_concat]]} {
      connect_bd_net [get_bd_pins jtagm/tck] [get_bd_pins ila_concat/In1]
      connect_bd_net [get_bd_pins jtagm/tms] [get_bd_pins ila_concat/In2]
      connect_bd_net [get_bd_pins jtagm/tdi] [get_bd_pins ila_concat/In3]
      connect_bd_net [get_bd_pins jtagm/tdo] [get_bd_pins ila_concat/In4]
    }
  }

  # --- addressing -----------------------------------------------------------
  assign_bd_address -quiet [get_bd_addr_segs -of_objects [get_bd_cells dbg_axi2bscan]]
  if {[llength [get_bd_cells -quiet jtagm]]} {
    assign_bd_address -quiet [get_bd_addr_segs -of_objects [get_bd_cells jtagm]]
    catch { set_property range 64K [get_bd_addr_segs /jtagm/s_axi/reg0] }
    catch { set_property offset 0x40000000 [get_bd_addr_segs /ps7/Data/SEG_jtagm_reg0] }
  }

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
foreach xdc [list [file join $script_dir constraints xvc.xdc] \
                  [file join $script_dir constraints jtag12.xdc]] {
  if {[file exists $xdc]} {
    add_files -fileset constrs_1 -norecurse $xdc
  }
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
file mkdir [file join $script_dir out]
open_run impl_1
write_debug_probes -force [file join $script_dir out system.ltx]
write_hw_platform -fixed -include_bit -force [file join $script_dir out system.xsa]
puts "XSA_WRITTEN [file join $script_dir out system.xsa]"
puts "FULL_BUILD_DONE"
