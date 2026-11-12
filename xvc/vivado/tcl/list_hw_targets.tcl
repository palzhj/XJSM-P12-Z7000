# list_hw_targets.tcl - what the local hw_server can see
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
foreach t [get_hw_targets] {
    puts "TARGET $t"
    catch {
        open_hw_target $t
        foreach d [get_hw_devices] {
            puts "   DEVICE $d"
        }
        close_hw_target
    } err
}
close_hw_manager
puts "TARGETS_DONE"
