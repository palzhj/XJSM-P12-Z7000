# program_cfgmem_usb.tcl — program the K7 configuration Flash with a USB JTAG cable
#
# Usage:
#   vivado -mode batch -source xvc/tools/program_cfgmem_usb.tcl \
#          -tclargs xc7k325t_0 /path/to/top.mcs
#
# Parameters:
#   device_name : FPGA name in the JTAG chain (usually xc7k325t_0 with a USB cable)
#   mcs_file    : .mcs or .bin
#
# Notes:
#   * this script **cannot** use -xvc_url (Vivado does not support Flash programming over XVC, see UG908 p.55)
#   * the Flash part must be s25fl256sxxxxxx1 (not xxxxxx0)
#   * prints the total elapsed time for easy record keeping

set device_name [lindex $argv 0]
set mcs_file    [lindex $argv 1]

if {$device_name == "" || $mcs_file == ""} {
    puts "Error: Usage: -tclargs <device_name> <mcs_file>"
    exit 1
}

open_hw_manager
connect_hw_server
if {[catch {open_hw_target} e]} {
    puts "OPEN_FAILED: $e"
    puts "Hint: make sure the USB JTAG cable is connected and -xvc_url is not used"
    close_hw_manager
    exit 1
}

set dev [get_hw_devices $device_name]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
puts "DEV: $dev"

set part [lindex [get_cfgmem_parts {s25fl256sxxxxxx1-spi-x1_x2_x4}] 0]
create_hw_cfgmem -hw_device $dev -mem_dev $part
set cfgMem [get_property PROGRAM.HW_CFGMEM $dev]
puts "CFGMEM: $cfgMem"

set_property PROGRAM.BLANK_CHECK 0 $cfgMem
set_property PROGRAM.ERASE       1 $cfgMem
set_property PROGRAM.CFG_PROGRAM 1 $cfgMem
set_property PROGRAM.VERIFY      1 $cfgMem
set_property PROGRAM.FILE $mcs_file $cfgMem

set t0 [clock milliseconds]
if {[catch {program_hw_cfgmem -hw_cfgmem $cfgMem} e]} {
    puts "FLASH_FAILED after [expr {[clock milliseconds]-$t0}] ms"
    puts "  ERR: $e"
} else {
    puts "FLASH_OK total=[expr {[clock milliseconds]-$t0}] ms"
}

close_hw_target
close_hw_manager
