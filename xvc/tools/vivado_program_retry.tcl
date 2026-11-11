open_hw_manager
connect_hw_server -url localhost:3121
set ok 0
for {set i 1} {$i <= 8} {incr i} {
    if {![catch {open_hw_target -xvc_url 192.168.1.113:2543
    # Pin TCK to 10 MHz (Vivado may request a slower clock by default)
    catch { set_property PARAM.FREQUENCY 10000000 [get_hw_targets -quiet] }
    catch { set_property PARAM.FREQUENCY 10000000 [current_hw_target] }} e]} {
        puts "OPEN_OK attempt $i devices=[get_hw_devices]"
        set ok 1
        break
    }
    puts "open attempt $i failed"
    after 500
    catch {close_hw_target}
}
if {!$ok} { puts "OPEN_GAVE_UP"; close_hw_manager; exit 1 }
set dev [lindex [get_hw_devices xc7k325t*] 0]
puts "TARGET: $dev"
set_property PROGRAM.FILE [file normalize test_bits/top-with-auto-neg.bit] $dev
set t0 [clock milliseconds]
if {[catch {program_hw_devices $dev} e]} { puts "PROGRAM_FAILED: $e" } else { puts "PROGRAM_OK in [expr {[clock milliseconds]-$t0}] ms" }
close_hw_target
close_hw_manager
