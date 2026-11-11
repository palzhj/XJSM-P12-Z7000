open_hw_manager
connect_hw_server -url localhost:3121
if {[catch {open_hw_target -xvc_url 192.168.1.50:2543} err]} {
    puts "OPEN_FAILED: $err"
    close_hw_manager
    exit 1
}
set devs [get_hw_devices]
puts "DEVICES: $devs"
set dev [lindex [get_hw_devices xc7k325t*] 0]
if {$dev eq ""} { puts "NO_K7"; close_hw_target; close_hw_manager; exit 1 }
puts "TARGET: $dev"
set_property PROGRAM.FILE [file normalize test_bits/top-with-auto-neg.bit] $dev
if {[catch {program_hw_devices $dev} e]} {
    puts "PROGRAM_FAILED: $e"
} else {
    puts "PROGRAM_OK"
}
close_hw_target
close_hw_manager
