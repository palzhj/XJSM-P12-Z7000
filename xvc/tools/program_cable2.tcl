open_hw_manager
connect_hw_server -url localhost:3121
set tgt localhost:3121/xilinx_tcf/Digilent/210249B1B270
open_hw_target $tgt
set dev [lindex [get_hw_devices xc7k325t*] 0]
puts "TARGET: $dev part=[get_property PART $dev] idcode=[get_property IDCODE_HEX $dev]"
set bit [file normalize test_bits/top-with-auto-neg.bit]
puts "BITFILE: $bit ([file size $bit] bytes)"
set_property PROGRAM.FILE $bit $dev
set t0 [clock milliseconds]
if {[catch {program_hw_devices $dev} e]} {
    puts "PROGRAM_FAILED after [expr {[clock milliseconds]-$t0}] ms"
    puts "  ERR: $e"
} else {
    puts "PROGRAM_OK in [expr {[clock milliseconds]-$t0}] ms"
    catch { puts "DONE_REGISTER=[get_property REGISTER.DONE $dev]" }
}
close_hw_target
close_hw_manager
