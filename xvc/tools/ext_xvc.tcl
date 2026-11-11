set ltx [file normalize "xvc/vivado/out_ext/system.ltx"]
open_hw_manager
connect_hw_server -url localhost:3121
current_hw_server localhost:3121
open_hw_target -xvc_url 192.168.1.113:2542
set dev [lindex [get_hw_devices] 0]
puts "=== dev=$dev"
current_hw_device $dev
refresh_hw_device -quiet
puts "=== ilas (no ltx): [get_hw_ilas]"
set_property PROBES.FILE $ltx $dev
after 500
refresh_hw_device -update_hw_probes true $dev
puts "=== after ltx+refresh: ilas=[get_hw_ilas] probes=[llength [get_hw_probes]]"
if {[llength [get_hw_ilas]] == 0} {
  set_property PROBES.FILE $ltx [current_hw_target]
  refresh_hw_target
  puts "=== after target refresh: ilas=[get_hw_ilas]"
}
close_hw_target
close_hw_manager
