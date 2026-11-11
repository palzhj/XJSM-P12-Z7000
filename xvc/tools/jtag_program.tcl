open_hw_manager
connect_hw_server -url localhost:3121
set tgt "localhost:3121/xilinx_tcf/Digilent/210512180081"
current_hw_target $tgt
open_hw_target
set dev [lindex [get_hw_devices xc7z020_1] 0]
current_hw_device $dev
puts "programming $dev ..."
create_hw_bitstream -hw_device $dev [file normalize "xvc/out/system_wrapper.bit"]
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
puts "=== devices after program:"
foreach d [get_hw_devices] { puts "   DEV $d" }
close_hw_target
close_hw_manager
