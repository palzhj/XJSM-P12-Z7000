# jtag_boot_rescue.tcl — boot U-Boot through the Zynq's own JTAG port without removing the card
#
# Usage (XSCT, not Vivado):
#   source /opt/Xilinx/Vivado/2022.2/settings64.sh
#   xsct xvc/tools/jtag_boot_rescue.tcl
#
# How it works:
#   1. Connect through hw_server to the on-board Digilent JTAG (attached to the Zynq TAP)
#   2. Reset the system -> load FSBL into OCM and run it (completes DDR/clock init)
#   3. Stop FSBL, load U-Boot into DDR and run it
#   4. A U-Boot prompt appears on the serial port -> repair the card with mmc/tftp/ums
#
# Depends on: images/linux/zynq_fsbl.elf, images/linux/u-boot.elf

set here [file dirname [file normalize [info script]]]
set img  [file join $here .. petalinux xvc images linux]

if {![file exists [file join $img zynq_fsbl.elf]]} {
    puts "!! cannot find [file join $img zynq_fsbl.elf]"
    exit 1
}

puts "== connecting hw_server"
connect
puts "== target list"
puts [targets]

puts "== resetting the system"
targets -set -nocase -filter {name =~ "*APU*" || name =~ "*ARM*#0"}
catch { rst -system }
after 3000

puts "== loading FSBL (initializes DDR/clocks)"
targets -set -nocase -filter {name =~ "*ARM*#0"}
dow [file join $img zynq_fsbl.elf]
con
after 3000

puts "== stopping FSBL and loading U-Boot"
catch { stop }
after 500
dow [file join $img u-boot.elf]
con

puts "== done: a U-Boot prompt should appear on the serial port"
puts "   run these on the serial console:"
puts "     setenv ipaddr 192.168.1.113"
puts "     setenv serverip 192.168.1.50"
puts "     tftpboot 0x02000000 image.ub"
puts "     mmc dev 0; fatwrite mmc 0 0x02000000 image.ub <hex length>"
puts "   or simply: ums 0 mmc 0   (exposes the SD card as a USB drive so the PC can copy files directly)"
