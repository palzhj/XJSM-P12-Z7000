open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target {localhost:3121/xilinx_tcf/Digilent/210512180081}
open_hw_target
set d [lindex [get_hw_devices xc7z020_1] 0]
refresh_hw_device -quiet $d
puts "=== props:"
foreach p [list_property $d] { puts "   $p = [get_property $p $d]" }
puts "ILA cores: [get_hw_ilas -of_objects $d]"
close_hw_target
close_hw_manager
