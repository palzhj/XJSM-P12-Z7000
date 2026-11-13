# xvc_connect.tcl - what does the XVC target expose?
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
if {[catch {open_hw_target -xvc_url 192.168.1.113:2543} err]} {
    puts "XVC_OPEN_FAILED: $err"
} else {
    puts "XVC_TARGET_OPEN"
    foreach d [get_hw_devices] {
        puts "DEV $d  done=[get_property REGISTER.IR.BIT4_DONE $d]  idcode=[get_property REGISTER.IDCODE $d]"
    }
    refresh_hw_device -update_hw_probes false [lindex [get_hw_devices] 0]
    catch { puts "ILAS: [get_hw_ilas]" }
    close_hw_target
}
puts "DONE_MARKER"
