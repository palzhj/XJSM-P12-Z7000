# Following the reference flow: PROGRAM.FILES (plural) + ADDRESS_RANGE + UNUSED_PIN_TERMINATION
open_hw_manager
connect_hw_server -url localhost:3121

set mcs [file normalize test_bits/top-with-auto-neg.mcs]
set ok 0
for {set i 1} {$i <= 8} {incr i} {
    if {![catch {open_hw_target -xvc_url 192.168.1.113:2543} e]} { set ok 1; break }
    after 500
    catch {close_hw_target}
}
if {!$ok} { puts "OPEN_GAVE_UP"; close_hw_manager; exit 1 }

set dev [lindex [get_hw_devices xc7k325t*] 0]
current_hw_device $dev
puts "TARGET: $dev"
refresh_hw_device -update_hw_probes false $dev

set part [lindex [get_cfgmem_parts {s25fl256sxxxxxx1-spi-x1_x2_x4}] 0]
puts "PART: $part"
create_hw_cfgmem -hw_device $dev -mem_dev $part
set cfg [get_property PROGRAM.HW_CFGMEM $dev]
puts "CFGMEM: $cfg"

set_property PROGRAM.FILES $mcs $cfg
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfg
set_property PROGRAM.BLANK_CHECK 0 $cfg
set_property PROGRAM.ERASE 1 $cfg
set_property PROGRAM.CFG_PROGRAM 1 $cfg
set_property PROGRAM.VERIFY 1 $cfg
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $cfg

puts "FILE_CHECK: [get_property PROGRAM.FILES $cfg]"
set t0 [clock milliseconds]
if {[catch {program_hw_cfgmem -hw_cfgmem $cfg} e]} {
    puts "FLASH_FAILED after [expr {[clock milliseconds]-$t0}] ms"
    puts "  ERR: $e"
} else {
    puts "FLASH_OK in [expr {[clock milliseconds]-$t0}] ms"
}
close_hw_target
close_hw_manager
