# build_jtag12p.tcl — 12 channels + 1 broadcast engine (clean version)
#
# Architecture:
#   13 identical jtag_ctrl instances (ch0..ch11 channels + bc broadcast)
#   1 jtag_bcast_regs register block (standalone AXI slave)
#   1 jtag_repeater combinational arbiter (per-channel TCK/TMS/TDI 1-of-2 + TDO 1-of-12)
#   axi_interconnect NUM_MI = 14 (12 channels + 1 broadcast engine + 1 register block)
#
# Addresses:
#   0x43C00000 + ch*0x10000   ch0..ch11
#   0x43CC0000                broadcast engine
#   0x43CD0000                broadcast control register block

set script_dir [file dirname [file normalize [info script]]]
set part       xc7z020clg400-2
set out_dir    [file join $script_dir out_jtag12p]
set proj       [file join $script_dir work_jtag12p]

file mkdir $out_dir
create_project -force jtag12p $proj -part $part

# ---- RTL ----
add_files -norecurse [file join $script_dir rtl jtag_ctrl.v]
add_files -norecurse [file join $script_dir rtl jtag_bcast_regs.v]
add_files -norecurse [file join $script_dir rtl jtag_repeater.v]
# OLED: PS7 I2C1 -> EMIO tri-state buffer
add_files -norecurse [file join $script_dir rtl i2c_emio.v]
add_files -fileset constrs_1 -norecurse [file join $script_dir constraints jtag12.xdc]
add_files -fileset constrs_1 -norecurse [file join $script_dir constraints oled_i2c.xdc]

create_bd_design "system"

# ---- PS7 ----
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
source [file join $script_dir tcl ps7_config.tcl]
apply_ps7_config [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]

# ---- reset and clocks ----
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/S_AXI_HP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins rst/ext_reset_in]

# ---- AXI Interconnect: 14 slaves ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi
set_property -dict [list CONFIG.NUM_MI {15} CONFIG.NUM_SI {1}] [get_bd_cells axi]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi/S00_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi/S00_ACLK]
connect_bd_net [get_bd_pins rst/interconnect_aresetn] [get_bd_pins axi/ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/S00_ARESETN]

# ---- 13 jtag_ctrl instances (M00..M12) ----
for {set i 0} {$i < 13} {incr i} {
    set n [format %02d $i]
    if {$i < 12} { set name jtag$i } else { set name bceng }
    create_bd_cell -type module -reference jtag_ctrl $name
    connect_bd_intf_net [get_bd_intf_pins $name/S_AXI] [get_bd_intf_pins axi/M${n}_AXI]
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0]   [get_bd_pins $name/clk]
    connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins $name/rstn]
    connect_bd_net [get_bd_pins ps7/FCLK_CLK0]   [get_bd_pins axi/M${n}_ACLK]
    connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/M${n}_ARESETN]
}

# ---- broadcast control register block (M13) ----
create_bd_cell -type module -reference jtag_bcast_regs bcregs
connect_bd_intf_net [get_bd_intf_pins bcregs/S_AXI] [get_bd_intf_pins axi/M13_AXI]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]   [get_bd_pins bcregs/clk]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins bcregs/rstn]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]   [get_bd_pins axi/M13_ACLK]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins axi/M13_ARESETN]

# ---- concatenate the 12 channels into buses ----
foreach sig {tck tms tdi tdo} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 cc_$sig
    set_property CONFIG.NUM_PORTS {12} [get_bd_cells cc_$sig]
}
for {set i 0} {$i < 12} {incr i} {
    foreach sig {tck tms tdi tdo} {
        connect_bd_net [get_bd_pins jtag$i/$sig] [get_bd_pins cc_${sig}/In$i]
    }
}
# TDO comes from the pins (connected below after the ports are created)

# ---- repeater ----
create_bd_cell -type module -reference jtag_repeater rep
# whether each channel follows broadcast -> each engine's bcast_sel
foreach {sig idx} {tck 0 tms 1 tdi 2} { }
for {set i 0} {$i < 12} {incr i} {
    create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 sl_follow$i
    set_property -dict [list CONFIG.DIN_WIDTH {12} CONFIG.DIN_FROM $i CONFIG.DIN_TO $i] [get_bd_cells sl_follow$i]
    connect_bd_net [get_bd_pins rep/follow] [get_bd_pins sl_follow$i/Din]
    connect_bd_net [get_bd_pins sl_follow$i/Dout] [get_bd_pins jtag$i/bcast_sel]
}
connect_bd_net [get_bd_pins cc_tck/dout] [get_bd_pins rep/ch_tck]
connect_bd_net [get_bd_pins cc_tms/dout] [get_bd_pins rep/ch_tms]
connect_bd_net [get_bd_pins cc_tdi/dout] [get_bd_pins rep/ch_tdi]
connect_bd_net [get_bd_pins bcregs/bcast_en]   [get_bd_pins rep/bcast_en]
connect_bd_net [get_bd_pins bcregs/bcmask_eff] [get_bd_pins rep/bcmask_eff]
connect_bd_net [get_bd_pins bcregs/chsel]      [get_bd_pins rep/chsel]
connect_bd_net [get_bd_pins bceng/tck] [get_bd_pins rep/bc_tck]
connect_bd_net [get_bd_pins bceng/tms] [get_bd_pins rep/bc_tms]
connect_bd_net [get_bd_pins bceng/tdi] [get_bd_pins rep/bc_tdi]
connect_bd_net [get_bd_pins rep/bc_tdo] [get_bd_pins bceng/tdo]
# the broadcast engine itself never "follows broadcast"; its bcast_sel is tied to 0
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_bc0
set_property CONFIG.CONST_WIDTH {1} [get_bd_cells const_bc0]
set_property CONFIG.CONST_VAL {0} [get_bd_cells const_bc0]
connect_bd_net [get_bd_pins const_bc0/dout] [get_bd_pins bceng/bcast_sel]

# ---- TDO pins (inputs): feed both the matching engine and the TDO bus ----
for {set i 1} {$i <= 12} {incr i} {
    set idx [expr {$i - 1}]
    create_bd_port -dir I jtag${i}_tdo
    connect_bd_net [get_bd_ports jtag${i}_tdo] [get_bd_pins jtag$idx/tdo] [get_bd_pins cc_tdo/In$idx]
}
connect_bd_net [get_bd_pins cc_tdo/dout] [get_bd_pins rep/ch_tdo]

# ---- TCK/TMS/TDI pins (outputs): slice the repeater outputs ----
for {set i 1} {$i <= 12} {incr i} {
    set idx [expr {$i - 1}]
    create_bd_port -dir O jtag${i}_tck
    create_bd_port -dir O jtag${i}_tms
    create_bd_port -dir O jtag${i}_tdi
    foreach sig {tck tms tdi} {
        create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 sl_${sig}${idx}
        set_property -dict [list CONFIG.DIN_WIDTH {12} CONFIG.DIN_FROM $idx CONFIG.DIN_TO $idx] \
            [get_bd_cells sl_${sig}${idx}]
        connect_bd_net [get_bd_pins rep/pin_${sig}] [get_bd_pins sl_${sig}${idx}/Din]
        connect_bd_net [get_bd_pins sl_${sig}${idx}/Dout] [get_bd_ports jtag${i}_${sig}]
    }
}

# ---- address mapping ----
for {set i 0} {$i < 12} {incr i} {
    set seg [get_bd_addr_segs jtag$i/s_axi/reg0]
    catch { set_property range 64K $seg }
    assign_bd_address -offset [format 0x%08X [expr {0x43C00000 + $i * 0x10000}]] -range 64K -target_address_space /ps7/Data $seg
}
set seg [get_bd_addr_segs bceng/s_axi/reg0]
catch { set_property range 64K $seg }
assign_bd_address -offset 0x43CC0000 -range 64K -target_address_space /ps7/Data $seg

set seg [get_bd_addr_segs bcregs/S_AXI/reg0]
catch { set_property range 64K $seg }
assign_bd_address -offset 0x43CD0000 -range 64K -target_address_space /ps7/Data $seg

# ---- AXI DMA: CPU-free bulk streaming into/out of jtag0's FIFOs ----
# MM2S : DDR -> jtag0.s_axis_tdi   (TDI words, TMS forced 0 by the engine)
# S2MM : jtag0.m_axis_tdo -> DDR   (captured TDO words)
# Both masters land on ps7/S_AXI_HP0 through a small 2-to-1 interconnect.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma
# c_sg_length_width sets the LENGTH register width in Register Direct mode too,
# not just for scatter-gather (AMD KB 51577). Left at its default of 14 the
# register truncates mod 16384, so a 16384-byte transfer programs a length of
# ZERO and the channel silently never starts; 23 bits is the most this IP
# supports (2^23-1 bytes).
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

# control port joins the existing Lite interconnect as M14 (NUM_MI 14 -> 15, set at creation)
connect_bd_net [get_bd_pins axi/M14_ACLK]    [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins axi/M14_ARESETN] [get_bd_pins rst/peripheral_aresetn]

connect_bd_intf_net [get_bd_intf_pins dma/S_AXI_LITE] [get_bd_intf_pins axi/M14_AXI]

# clocks / reset
connect_bd_net [get_bd_pins dma/s_axi_lite_aclk]    [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins dma/m_axi_mm2s_aclk]    [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins dma/m_axi_s2mm_aclk]    [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins dma/axi_resetn]         [get_bd_pins rst/peripheral_aresetn]
connect_bd_net [get_bd_pins dma_ic/ACLK]            [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins dma_ic/S00_ACLK]        [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins dma_ic/S01_ACLK]        [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins dma_ic/M00_ACLK]        [get_bd_pins ps7/FCLK_CLK0]
connect_bd_net [get_bd_pins dma_ic/ARESETN]         [get_bd_pins rst/peripheral_aresetn]
connect_bd_net [get_bd_pins dma_ic/S00_ARESETN]     [get_bd_pins rst/peripheral_aresetn]
connect_bd_net [get_bd_pins dma_ic/S01_ARESETN]     [get_bd_pins rst/peripheral_aresetn]
connect_bd_net [get_bd_pins dma_ic/M00_ARESETN]     [get_bd_pins rst/peripheral_aresetn]
# ps7/S_AXI_HP0_ACLK is auto-connected by Vivado

# stream wiring: only channel 0 gets the DMA; the other 12 engines tie off
connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S] [get_bd_intf_pins jtag0/s_axis_tdi]
connect_bd_intf_net [get_bd_intf_pins jtag0/m_axis_tdo] [get_bd_intf_pins dma/S_AXIS_S2MM]
# the interface carries m_axis_tdo_tlast, which S2MM needs to terminate a transfer


create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 dma_on
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells dma_on]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 dma_off
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells dma_off]

connect_bd_net [get_bd_pins dma_on/dout]  [get_bd_pins jtag0/dma_en]
for {set i 1} {$i < 12} {incr i} {
    connect_bd_net [get_bd_pins dma_off/dout] [get_bd_pins jtag$i/dma_en]
    connect_bd_net [get_bd_pins dma_off/dout] [get_bd_pins jtag$i/s_axis_tdi_tvalid]
    connect_bd_net [get_bd_pins dma_off/dout] [get_bd_pins jtag$i/m_axis_tdo_tready]
}
connect_bd_net [get_bd_pins dma_off/dout] [get_bd_pins bceng/dma_en]
connect_bd_net [get_bd_pins dma_off/dout] [get_bd_pins bceng/s_axis_tdi_tvalid]
connect_bd_net [get_bd_pins dma_off/dout] [get_bd_pins bceng/m_axis_tdo_tready]

# let both DMA masters reach DDR through HP0
assign_bd_address -target_address_space /dma/Data_MM2S [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM]
assign_bd_address -target_address_space /dma/Data_S2MM [get_bd_addr_segs ps7/S_AXI_HP0/HP0_DDR_LOWOCM]

# DMA register block: 0x40400000
set seg [get_bd_addr_segs dma/S_AXI_LITE/Reg]
catch { set_property range 64K $seg }
assign_bd_address -offset 0x40400000 -range 64K -target_address_space /ps7/Data $seg

# ---- OLED I2C: PS7 EMIO -> IOBUF -> J20 pin35/pin33 (V15/U20) ----
create_bd_cell -type module -reference i2c_emio i2c_emio_0
create_bd_port -dir IO i2c_scl
create_bd_port -dir IO i2c_sda
connect_bd_net [get_bd_pins i2c_emio_0/i2c_scl] [get_bd_ports i2c_scl]
connect_bd_net [get_bd_pins i2c_emio_0/i2c_sda] [get_bd_ports i2c_sda]
# PS7 EMIO I2C1 pins: *_I are outputs (into the PS), *_O/*_T are inputs (out of the PS)
connect_bd_net [get_bd_pins ps7/I2C1_SCL_I] [get_bd_pins i2c_emio_0/scl_i]
connect_bd_net [get_bd_pins ps7/I2C1_SCL_O] [get_bd_pins i2c_emio_0/scl_o]
connect_bd_net [get_bd_pins ps7/I2C1_SCL_T] [get_bd_pins i2c_emio_0/scl_t]
connect_bd_net [get_bd_pins ps7/I2C1_SDA_I] [get_bd_pins i2c_emio_0/sda_i]
connect_bd_net [get_bd_pins ps7/I2C1_SDA_O] [get_bd_pins i2c_emio_0/sda_o]
connect_bd_net [get_bd_pins ps7/I2C1_SDA_T] [get_bd_pins i2c_emio_0/sda_t]

save_bd_design
validate_bd_design
generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files -norecurse [file join $proj jtag12p.gen sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---- synthesis/implementation/bitstream ----
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
write_hw_platform -fixed -include_bit -force [file join $out_dir system.xsa]
puts "BUILD_DONE"
