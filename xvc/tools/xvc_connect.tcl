open_hw_manager
connect_hw_server -url localhost:3121
current_hw_server localhost:3121
open_hw_target -xvc_url 192.168.1.110:2542
puts "=== xvc target: [current_hw_target]"
foreach d [get_hw_devices] {
  puts "   DEV $d  IDCODE=[get_property IDCODE $d]"
}
current_hw_device [lindex [get_hw_devices] 0]
refresh_hw_device -quiet
puts "=== after refresh:"
foreach d [get_hw_devices] { puts "   DEV $d" }
close_hw_target
close_hw_manager
