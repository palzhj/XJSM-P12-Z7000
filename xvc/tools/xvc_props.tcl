open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -xvc_url 192.168.1.113:2542
set d [lindex [get_hw_devices] 0]
puts "=== device: $d"
foreach p [list_property $d] { puts "   $p = [get_property $p $d]" }
close_hw_target
close_hw_manager
