# build_single.tcl - ONE JTAG channel on J20 G1, built three ways.
#
#   vivado -mode batch -source build_single.tcl -tclargs reg
#   vivado -mode batch -source build_single.tcl -tclargs fifo
#   vivado -mode batch -source build_single.tcl -tclargs dma
#
# Only what each path needs is present, so the three measurements cannot
# borrow speed from a feature they are not supposed to use:
#
#   reg   jtag_ctrl with USE_FIFO=0  - TX/RX queues pruned; the chunked
#         register path (PG245 From_AXI_to_JTAG style) is the only way in.
#   fifo  jtag_ctrl with USE_FIFO=1  - the 128-entry queues, stream ports tied
#         off, no DMA in the design.
#   dma   jtag_ctrl with USE_FIFO=1 + axi_dma on AXI-Stream, MM2S/S2MM into
#         ps7 S_AXI_HP0.
#
# Single channel: jtag_ctrl at 0x43C00000, pins R14/P14/U12/T12 (G1).

set mode [expr {[llength $argv] ? [lindex $argv 0] : "fifo"}]
switch -- $mode {
    reg  { set use_fifo 0 }
    fifo { set use_fifo 1 }
    dma  { set use_fifo 1 }
    default { puts "MODE must be reg|fifo|dma, got '$mode'"; exit 1 }
}

set script_dir [file dirname [file normalize [info script]]]
set part       xc7z020clg400-2
set name       single_$mode
set out_dir    [file join $script_dir out_$name]
set proj       [file join $script_dir work_$name]

file mkdir $out_dir
create_project -force $name $proj -part $part

add_files -norecurse [file join $script_dir rtl jtag_ctrl.v]
add_files -fileset constrs_1 -norecurse [file join $script_dir constraints g1_single.xdc]

create_bd_design "system"

# ---- PS7 ----
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
source [file join $script_dir tcl ps7_config.tcl]
apply_ps7_config [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst/ext_reset_in]
# HP0 is enabled in the PS7 config whether or not the DMA uses it, so its ACLK
# must be driven; without the DMA nothing else wires it up and validate fails.
catch { connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/S_AXI_HP0_ACLK] }

# ---- control interconnect: GP0 -> jtag_ctrl (+ axi_dma lite for dma mode) ----
set nmi [expr {$mode eq "dma" ? 2 : 1}]
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi
set_property -dict [list CONFIG.NUM_MI $nmi CONFIG.NUM_SI 1] [get_bd_cells axi]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi/S00_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/S00_ACLK]
connect_bd_net [get_bd_pins rst/interconnect_aresetn] [get_bd_pins axi/ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/S00_ARESETN]
foreach n {M00 M01} {
    if {$n == "M01" && $nmi < 2} { continue }
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0]   [get_bd_pins axi/${n}_ACLK]
    connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/${n}_ARESETN]
}

# ---- the one JTAG engine ----
create_bd_cell -type module -reference jtag_ctrl jtag0
set_property -dict [list CONFIG.USE_FIFO $use_fifo CONFIG.DIV_DEFAULT 5] [get_bd_cells jtag0]
connect_bd_intf_net [get_bd_intf_pins jtag0/S_AXI] [get_bd_intf_pins axi/M00_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins jtag0/clk]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins jtag0/rstn]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 bsel0
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells bsel0]
connect_bd_net [get_bd_pins bsel0/dout] [get_bd_pins jtag0/bcast_sel]

create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 dn_en
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL [expr {$mode eq "dma" ? 1 : 0}]] [get_bd_cells dn_en]
connect_bd_net [get_bd_pins dn_en/dout] [get_bd_pins jtag0/dma_en]

# ---- pins: one G1 port ----
create_bd_port -dir O jtag_tck
create_bd_port -dir O jtag_tms
create_bd_port -dir O jtag_tdi
create_bd_port -dir I jtag_tdo
connect_bd_net [get_bd_pins jtag0/tck] [get_bd_ports jtag_tck]
connect_bd_net [get_bd_pins jtag0/tms] [get_bd_ports jtag_tms]
connect_bd_net [get_bd_pins jtag0/tdi] [get_bd_ports jtag_tdi]
connect_bd_net [get_bd_ports jtag_tdo] [get_bd_pins jtag0/tdo]

# ---- stream ports ----
if {$mode eq "dma"} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma
    set_property -dict [list \
        CONFIG.c_include_sg {0} \
        CONFIG.c_sg_include_stscntrl_strm {0} \
        CONFIG.c_sg_length_width {23} \
        CONFIG.c_include_mm2s {1} \
        CONFIG.c_include_s2mm {1} \
        CONFIG.c_m_axi_mm2s_data_width {64} \
        CONFIG.c_m_axis_mm2s_tdata_width {32} \
        CONFIG.c_m_axi_s2mm_data_width {64} \
        CONFIG.c_s_axis_s2mm_tdata_width {32} \
    ] [get_bd_cells dma]

    create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 dma_ic
    set_property -dict [list \
        CONFIG.NUM_MI {1} CONFIG.NUM_SI {2} \
        CONFIG.S00_DATA_WIDTH {64} CONFIG.S01_DATA_WIDTH {64} \
        CONFIG.M00_DATA_WIDTH {64} \
    ] [get_bd_cells dma_ic]
    connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_MM2S] [get_bd_intf_pins dma_ic/S00_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_S2MM] [get_bd_intf_pins dma_ic/S01_AXI]
    connect_bd_intf_net [get_bd_intf_pins dma_ic/M00_AXI] [get_bd_intf_pins ps7/S_AXI_HP0]
    connect_bd_intf_net [get_bd_intf_pins dma/S_AXI_LITE] [get_bd_intf_pins axi/M01_AXI]

    connect_bd_net [get_bd_pins dma/s_axi_lite_aclk] [get_bd_pins ps7/FCLK_CLK0]
    connect_bd_net [get_bd_pins dma/m_axi_mm2s_aclk] [get_bd_pins ps7/FCLK_CLK0]
    connect_bd_net [get_bd_pins dma/m_axi_s2mm_aclk] [get_bd_pins ps7/FCLK_CLK0]
    connect_bd_net [get_bd_pins dma/axi_resetn]      [get_bd_pins rst/peripheral_aresetn]
    connect_bd_net [get_bd_pins dma_ic/ACLK]         [get_bd_pins ps7/FCLK_CLK0]
    connect_bd_net [get_bd_pins dma_ic/S00_ACLK]     [get_bd_pins ps7/FCLK_CLK0]
    connect_bd_net [get_bd_pins dma_ic/S01_ACLK]     [get_bd_pins ps7/FCLK_CLK0]
    connect_bd_net [get_bd_pins dma_ic/M00_ACLK]     [get_bd_pins ps7/FCLK_CLK0]
    connect_bd_net [get_bd_pins dma_ic/ARESETN]      [get_bd_pins rst/peripheral_aresetn]
    connect_bd_net [get_bd_pins dma_ic/S00_ARESETN]  [get_bd_pins rst/peripheral_aresetn]
    connect_bd_net [get_bd_pins dma_ic/S01_ARESETN]  [get_bd_pins rst/peripheral_aresetn]
    connect_bd_net [get_bd_pins dma_ic/M00_ARESETN]  [get_bd_pins rst/peripheral_aresetn]

    connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S] [get_bd_intf_pins jtag0/s_axis_tdi]
    connect_bd_intf_net [get_bd_intf_pins jtag0/m_axis_tdo] [get_bd_intf_pins dma/S_AXIS_S2MM]
} else {
    # no DMA in the design: the stream ports cannot be used even by accident
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 off0
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells off0]
    connect_bd_net [get_bd_pins off0/dout] [get_bd_pins jtag0/s_axis_tdi_tvalid]
    connect_bd_net [get_bd_pins off0/dout] [get_bd_pins jtag0/m_axis_tdo_tready]
}

# ---- address map ----
set seg [get_bd_addr_segs jtag0/s_axi/reg0]
catch { set_property range 64K $seg }
assign_bd_address -offset 0x43C00000 -range 64K -target_address_space /ps7/Data $seg
if {$mode eq "dma"} {
    assign_bd_address -target_address_space /dma/Data_MM2S [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM]
    assign_bd_address -target_address_space /dma/Data_S2MM [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM]
    set seg [get_bd_addr_segs dma/S_AXI_LITE/Reg]
    catch { set_property range 64K $seg }
    assign_bd_address -offset 0x40400000 -range 64K -target_address_space /ps7/Data $seg
}

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
