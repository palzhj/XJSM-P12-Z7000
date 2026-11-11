open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -xvc_url 192.168.1.113:2543
set dev [lindex [get_hw_devices xc7k325t*] 0]
puts "TARGET: $dev"
set_property PROGRAM.FILE [file normalize test_bits/top-with-auto-neg.bit] $dev
set t0 [clock milliseconds]
if {[catch {program_hw_devices $dev} e]} { puts "PROGRAM_FAILED: $e" } else { puts "PROGRAM_OK in [expr {[clock milliseconds]-$t0}] ms" }
close_hw_target
close_hw_manager
