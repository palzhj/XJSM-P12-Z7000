# flash_program_xvc.tcl — program the K7 configuration Flash with Vivado Tcl over XVC
#
# Usage:
#   vivado -mode batch -source xvc/tools/flash_program_xvc.tcl \
#          -tclargs <mcs_file> [verify]
#
# Key point: the "SPI bridge" bitstream shipped with Vivado must be programmed first, otherwise program_hw_cfgmem
#       reports 27-3347 "Failure to set flash parameters" (the GUI does this step automatically)
#
# Bridge file: bitfile/spi_xc7k325t_*.bit inside <Vivado>/data/xicom/cfgmem/bitfile.zip

set mcs_file [lindex $argv 0]
set do_verify [lindex $argv 1]
if {$do_verify == ""} { set do_verify 1 }

if {$mcs_file == ""} {
    puts "Usage: -tclargs <mcs_file> \[verify\]"
    exit 1
}

set bridge {/run/media/iheper/a435849f-51ca-4a93-abc2-5d48c0bc1de3/work/XJSM-P12-Z7000/xvc/out/bridge/spi_xc7k325t_pullnone.bit}

open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 1} {$i <= 8} {incr i} {
    if {![catch {open_hw_target -xvc_url 192.168.1.113:2543} e]} { set ok 1; break }
    after 500; catch {close_hw_target}
}
if {!$ok} { puts "OPEN_GAVE_UP"; close_hw_manager; exit 1 }

set dev [lindex [get_hw_devices xc7k325t*] 0]
refresh_hw_device -update_hw_probes false $dev
puts "DEV: $dev"

# ---- 1) program the SPI bridge ----
set t0 [clock milliseconds]
set_property PROGRAM.FILE $bridge $dev
if {[catch {program_hw_devices $dev} e]} {
    puts "BRIDGE_FAIL: $e"; close_hw_target; close_hw_manager; exit 1
}
puts "BRIDGE_OK [expr {[clock milliseconds]-$t0}] ms"
after 1000

# ---- 2) program the Flash ----
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {s25fl256sxxxxxx1-spi-x1_x2_x4}] 0]
set cfg [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.FILES [list [file normalize $mcs_file]] $cfg
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfg
set_property PROGRAM.BLANK_CHECK 0 $cfg
set_property PROGRAM.ERASE 1 $cfg
set_property PROGRAM.CFG_PROGRAM 1 $cfg
set_property PROGRAM.VERIFY $do_verify $cfg

set t1 [clock milliseconds]
if {[catch {program_hw_cfgmem -hw_cfgmem $cfg} e]} {
    puts "FLASH_FAILED after [expr {[clock milliseconds]-$t1}] ms"
    puts "  ERR: $e"
} else {
    puts "FLASH_OK erase+program=[expr {[clock milliseconds]-$t1}] ms (verify=$do_verify)"
    puts "TOTAL=[expr {[clock milliseconds]-$t0}] ms"
}
close_hw_target
close_hw_manager
