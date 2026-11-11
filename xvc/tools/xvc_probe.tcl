open_hw_manager
connect_hw_server -url localhost:3121
current_hw_server localhost:3121
open_hw_target -xvc_url 192.168.1.110:2542
puts "=== target devices:"
foreach d [get_hw_devices] { puts "   DEV $d  IDCODE=[get_property IDCODE $d] PART=[get_property PART $d]" }
set dev [lindex [get_hw_devices] 0]
set_property PROBES.FILE [file normalize "xvc/out/system.ltx"] $dev
set_property FULL_PROBES.FILE [file normalize "xvc/out/system.ltx"] $dev
refresh_hw_device -update_hw_probes true $dev
puts "=== all ilas: [get_hw_ilas]"
puts "=== all probes: [get_hw_probes]"
foreach d [get_hw_devices] {
  puts "   $d -> ilas: [get_hw_ilas -of_objects $d]"
}
close_hw_target
close_hw_manager
