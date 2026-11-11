open_hw_manager
connect_hw_server -url localhost:3121
if {[catch {open_hw_target -xvc_url 192.168.1.113:2543} e]} { puts "OPEN_FAIL: $e" } else { puts "OPEN_OK [get_hw_devices]"; close_hw_target }
close_hw_manager
