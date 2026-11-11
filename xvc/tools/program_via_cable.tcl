open_hw_manager
connect_hw_server -url localhost:3121
set done 0
foreach tgt [get_hw_targets *Digilent*] {
    if {[catch {open_hw_target $tgt} e]} { puts "OPEN_FAIL $tgt"; continue }
    set devs [get_hw_devices]
    puts "TARGET $tgt DEVICES: $devs"
    set dev [lindex [get_hw_devices xc7k325t*] 0]
    if {$dev eq ""} { close_hw_target; continue }
    puts "TARGET: $dev part=[get_property PART $dev] idcode=[get_property IDCODE_HEX $dev]"
    set bit [file normalize test_bits/top-with-auto-neg.bit]
    set_property PROGRAM.FILE $bit $dev
    set t0 [clock milliseconds]
    if {[catch {program_hw_devices $dev} e]} {
        puts "PROGRAM_FAILED after [expr {[clock milliseconds]-$t0}] ms: $e"
    } else {
        puts "PROGRAM_OK in [expr {[clock milliseconds]-$t0}] ms"
        catch { puts "DONE_REGISTER=[get_property REGISTER.DONE $dev]" }
        set done 1
    }
    close_hw_target
    if {$done} break
}
if {!$done} { puts "NO_K7_PROGRAMMED" }
close_hw_manager
