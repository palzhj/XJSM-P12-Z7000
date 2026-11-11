set ltx [file normalize "xvc/out/system.ltx"]
set bit [file normalize "xvc/out/system_wrapper.bit"]
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -xvc_url 192.168.1.113:2542
set d [lindex [get_hw_devices] 0]
current_hw_device $d
set_property PROGRAM.FILE $bit $d
set_property PROBES.FILE $ltx $d
refresh_hw_device -update_hw_probes true $d
puts "=== ilas: [get_hw_ilas -of_objects $d]"
close_hw_target
close_hw_manager
