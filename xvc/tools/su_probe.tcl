set ltx [file normalize "xvc/vivado/out_su/system.ltx"]
open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target {localhost:3121/xilinx_tcf/Digilent/210512180081}
open_hw_target
set j [lindex [get_hw_devices xc7z020_1] 0]
current_hw_device $j
create_hw_bitstream -hw_device $j [file normalize "xvc/vivado/work_su/xvc_su.runs/impl_1/system_wrapper.bit"]
program_hw_devices $j
puts "=== programmed"
close_hw_target
after 2000
open_hw_target -xvc_url 192.168.1.110:2542
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev
puts "=== ilas: [get_hw_ilas -of_objects $dev]"
close_hw_target
close_hw_manager
