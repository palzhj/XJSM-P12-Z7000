# flash_timed.tcl — program the S25FL256S and time it
open_hw_manager
connect_hw_server -url localhost:3121

set ok 0
for {set i 1} {$i <= 8} {incr i} {
    if {![catch {open_hw_target -xvc_url 192.168.1.113:2543} e]} { set ok 1; break }
    after 500
    catch {close_hw_target}
}
if {!$ok} { puts "OPEN_GAVE_UP"; close_hw_manager; exit 1 }

set dev [lindex [get_hw_devices xc7k325t*] 0]
puts "DEV: $dev"
refresh_hw_device -update_hw_probes false $dev

set part [lindex [get_cfgmem_parts {s25fl256sxxxxxx1-spi-x1_x2_x4}] 0]
puts "PART: $part"
create_hw_cfgmem -hw_device $dev -mem_dev $part
set cfg [get_property PROGRAM.HW_CFGMEM $dev]
puts "CFGMEM: $cfg"

set_property PROGRAM.FILES [list [file normalize test_bits/top-with-auto-neg.mcs]] $cfg
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfg
set_property PROGRAM.BLANK_CHECK 0 $cfg
set_property PROGRAM.ERASE 1 $cfg
set_property PROGRAM.CFG_PROGRAM 1 $cfg
set_property PROGRAM.VERIFY 0 $cfg
set_property PROGRAM.CHECKSUM 0 $cfg

set t0 [clock milliseconds]
if {[catch {program_hw_cfgmem -hw_cfgmem $cfg} e]} {
    set t1 [clock milliseconds]
    puts "FLASH_FAILED after [expr {$t1-$t0}] ms"
    puts "  ERR: $e"
} else {
    set t1 [clock milliseconds]
    puts "FLASH_OK total=[expr {$t1-$t0}] ms"
}
close_hw_target
close_hw_manager
