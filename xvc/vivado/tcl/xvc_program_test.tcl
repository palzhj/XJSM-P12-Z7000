# xvc_program_test.tcl - program the KU15P over XVC with test_bits/ and bind the
# probes file, reporting IDCODE/DONE/ILAs at each step.
set BIT [file normalize test_bits/top.bit]
set LTX [file normalize test_bits/top.ltx]
puts "BIT $BIT"
puts "LTX $LTX"

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
if {[catch {open_hw_target -xvc_url 192.168.1.113:2543} err]} {
    puts "OPEN_FAILED: $err"
    exit
}
puts "TARGET_OPEN"
set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { puts "NO_DEVICE"; exit }
puts "DEV        $dev"
puts "IDCODE     [get_property REGISTER.IDCODE $dev]"
puts "DONE_BEFORE [expr {[catch {get_property REGISTER.IR.BIT4_DONE $dev} d] ? "?" : $d}]"

current_hw_device $dev
set_property PROGRAM.FILE $BIT $dev
if {[catch {program_hw_devices $dev} err]} {
    puts "PROGRAM_FAILED: $err"
} else {
    puts "PROGRAMMED"
}
catch { puts "DONE_AFTER [get_property REGISTER.IR.BIT4_DONE $dev]" }

set_property PROBES.FILE      $LTX $dev
set_property FULL_PROBES.FILE $LTX $dev
if {[catch {refresh_hw_device -update_hw_probes true $dev} err]} {
    puts "REFRESH_FAILED: $err"
} else {
    puts "REFRESHED"
}
catch { puts "HUB  [get_hw_debug_hubs]" }
catch { puts "ILAS [get_hw_ilas]" }
puts "PROBES_FILE [get_property PROBES.FILE $dev]"
close_hw_target
close_hw_manager
puts "SCRIPT_DONE"
