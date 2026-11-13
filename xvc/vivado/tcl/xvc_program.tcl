# xvc_program.tcl - program a device through an XVC server and bind its probes.
#
#   vivado -mode batch -source xvc_program.tcl -tclargs <ip:port> <bit> <ltx>
#   e.g. ... -tclargs 192.168.1.113:2543 test_bits/top.bit test_bits/top.ltx
#
# Verified working against 192.168.1.113:2543 (xcku15p_0) with Vivado 2022.2:
# programming reports DONE, the probes file binds, and get_hw_ilas returns
# hw_ila_1. So the "ILA not visible over XVC" symptom is NOT inherent to XVC -
# it comes from a stale probes association, or from a device that is not
# running the bitstream that the .ltx was generated for.
#
# GOTCHA, learned the hard way: hw_server keeps the XVC target open. If a
# session dies (or you forget close_hw_target) the next open_hw_target reports
# "[Labtools 27-2269] No devices detected" and stays that way until hw_server
# is restarted. Start one hw_server per session and always close the target.
set XVC [lindex $argv 0]
set BIT [lindex $argv 1]
set LTX [lindex $argv 2]
if {$XVC eq "" || $BIT eq ""} {
    puts "usage: -tclargs <ip:port> <bitstream> \[probes.ltx\]"
    exit 1
}

open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
if {[catch {open_hw_target -xvc_url $XVC} err]} {
    puts "OPEN_FAILED: $err"
    puts "  -> if this says 'No devices detected', restart hw_server and retry"
    exit 1
}

set dev [lindex [get_hw_devices] 0]
if {$dev eq ""} { puts "NO_DEVICE"; close_hw_target; exit 1 }
current_hw_device $dev
puts "DEVICE   $dev"
puts "IDCODE   [get_property IDCODE $dev]"

set_property PROGRAM.FILE $BIT $dev
if {[catch {program_hw_devices $dev} err]} { puts "PROGRAM_FAILED: $err" } else { puts "PROGRAMMED_OK" }

if {$LTX ne ""} {
    # Attach the probes file explicitly. Without this the debug hub and ILAs
    # never appear, even though the core is in the fabric.
    set_property PROBES.FILE      $LTX $dev
    set_property FULL_PROBES.FILE $LTX $dev
    if {[catch {refresh_hw_device -update_hw_probes true $dev} err]} {
        puts "REFRESH_FAILED: $err"
    } else {
        puts "REFRESHED_OK"
    }
    puts "HUBS     [get_hw_debug_hubs]"
    foreach ila [get_hw_ilas] {
        puts "ILA      $ila  probes=[llength [get_hw_probes -of_objects $ila]]"
    }
}

close_hw_target
close_hw_manager
puts "DONE"
