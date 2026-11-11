set ltx [file normalize "xvc/vivado/out_ext/system.ltx"]
open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target {localhost:3121/xilinx_tcf/Digilent/210512180081}
open_hw_target
set j [lindex [get_hw_devices xc7z020_1] 0]
current_hw_device $j
create_hw_bitstream -hw_device $j [file normalize "xvc/vivado/work_ext/xvc_ext.runs/impl_1/system_wrapper.bit"]
program_hw_devices $j
puts "=== programmed ext"
close_hw_target
close_hw_manager
