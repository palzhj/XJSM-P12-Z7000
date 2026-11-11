open_hw_manager
connect_hw_server -url localhost:3121
set dev ""
foreach tgt [get_hw_targets] {
    if {[catch {open_hw_target $tgt} e]} continue
    set d [lindex [get_hw_devices xc7z020*] 0]
    if {$d ne ""} { set dev $d; set found $tgt; break }
    catch {close_hw_target}
}
if {$dev eq ""} { puts "NO_ZYNQ_TARGET"; close_hw_manager; exit 1 }
puts "TARGET: $dev"
set_property PROBES.FILE {xvc/vivado/out_g1/system.ltx} $dev
set_property FULL_PROBES.FILE {xvc/vivado/out_g1/system.ltx} $dev
refresh_hw_device -update_hw_probes true $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
puts "ILA: $ila probes=[get_hw_probes -of_objects $ila]"
# Trigger: probe0 bit0 = tck rising edge (probe0[0]=1)
set p [lindex [get_hw_probes -of_objects $ila] 0]
if {[catch {set_property TRIGGER_COMPARE_VALUE eq4'b0001 $p} e]} { puts "TRIG_SET_FAIL: $e" }
run_hw_ila $ila
after 5000
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file xvc/out/ila_jtag_cap.csv $data
puts "CSV_DONE"
close_hw_target
close_hw_manager
