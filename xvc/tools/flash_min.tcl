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
puts "TARGET: $dev"
set parts [get_cfgmem_parts {s25fl256sxxxxxx0-spi-x1_x2_x4}]
create_hw_cfgmem -hw_device $dev [lindex $parts 0]
set cfg [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.BLANK_CHECK 0 $cfg
set_property PROGRAM.ERASE       1 $cfg
set_property PROGRAM.CFG_PROGRAM 1 $cfg
set_property PROGRAM.VERIFY      0 $cfg
set_property PROGRAM.CHECKSUM    0 $cfg
set_property PROGRAM.FILE [file normalize xvc/out/k7_flash.bin] $cfg
puts "PROPS: [list [get_property PROGRAM.FILE $cfg]]"
if {[catch {program_hw_cfgmem -hw_cfgmem $cfg} e]} { puts "FLASH_FAILED: $e" } else { puts "FLASH_OK" }
close_hw_target
close_hw_manager
