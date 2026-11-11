open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -xvc_url 192.168.1.113:2543
set dev [lindex [get_hw_devices] 0]
puts "DEV=$dev"
puts "IDCODE=[get_property IDCODE_HEX $dev]"
puts "PART=[get_property PART $dev]"
foreach p [list_property $dev] { if {[string match PROGRAM.* $p]} { catch { puts "  $p=[get_property $p $dev]" } } }
close_hw_target
close_hw_manager
