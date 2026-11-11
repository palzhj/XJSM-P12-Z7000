open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -xvc_url 192.168.1.113:2543
set dev [lindex [get_hw_devices xc7k325t*] 0]
puts "TARGET: $dev"
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {s25fl256sxxxxxx0-spi-x1_x2_x4}] 0]
set cfg [get_property PROGRAM.HW_CFGMEM $dev]
puts "CFGMEM: $cfg"
foreach p {PROGRAM.BLANK_CHECK PROGRAM.ERASE PROGRAM.CFG_PROGRAM PROGRAM.VERIFY} {
    catch { set_property $p 0 $cfg }
}
set_property PROGRAM.FILE [file normalize test_bits/top-with-auto-neg.mcs] $cfg
set_property PROGRAM.BLANK_CHECK 1 $cfg
if {[catch {program_hw_cfgmem -hw_cfgmem $cfg} e]} { puts "CHECK_FAILED: $e" } else { puts "CHECK_OK" }
close_hw_target
close_hw_manager
