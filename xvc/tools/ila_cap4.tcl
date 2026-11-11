open_hw_manager
connect_hw_server -url localhost:3121
set dev ""
foreach tgt [get_hw_targets] {
    if {[catch {open_hw_target $tgt} e]} continue
    set d [lindex [get_hw_devices xc7z020*] 0]
    if {$d ne ""} { set dev $d; break }
    catch {close_hw_target}
}
if {$dev eq ""} { puts "NO_ZYNQ"; close_hw_manager; exit 1 }
puts "TARGET: $dev"
set_property PROBES.FILE {xvc/vivado/out_g1/system.ltx} $dev
set_property FULL_PROBES.FILE {xvc/vivado/out_g1/system.ltx} $dev
refresh_hw_device -update_hw_probes true $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
set probes [get_hw_probes -of_objects $ila]
puts "PROBES: $probes"
set tck [lindex $probes 1]
if {[catch {set_property TRIGGER_COMPARE_VALUE eq1'b1 $tck} e]} { puts "TRIGFAIL: $e" }
catch { set_property TRIGGER_POSITION 100 $ila }
run_hw_ila $ila
after 8000
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file xvc/out/ila_cap4.csv $data
puts "CSV_DONE"
close_hw_target
close_hw_manager
