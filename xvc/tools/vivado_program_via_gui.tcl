# Reuse the hw_server already started by the GUI (localhost:3121), find the XVC target and program it
open_hw_manager
connect_hw_server -url localhost:3121
puts "TARGETS: [get_hw_targets]"
set tgt [lindex [get_hw_targets *xvc*] 0]
if {$tgt eq ""} { set tgt [lindex [get_hw_targets] 1] }
puts "USING: $tgt"
if {[catch {open_hw_target $tgt} e]} { puts "OPEN_FAILED: $e"; close_hw_manager; exit 1 }
set dev [lindex [get_hw_devices xc7k325t*] 0]
puts "DEV: $dev part=[get_property PART $dev]"
set_property PROGRAM.FILE {test_bits/top-with-auto-neg.bit} $dev
if {[catch {program_hw_devices $dev} e]} { puts "PROGRAM_FAILED: $e" } else { puts "PROGRAM_OK" }
close_hw_target
close_hw_manager
