open_hw_manager
connect_hw_server -url localhost:3121
set tgt localhost:3121/xilinx_tcf/Digilent/210512180081
if {[catch {open_hw_target $tgt} e]} { puts "ERR_OPEN: $e"; close_hw_manager; exit 1 }
set dev [lindex [get_hw_devices xc7z020*] 0]
set_property PROBES.FILE {xvc/vivado/out_g1/system.ltx} $dev
set_property FULL_PROBES.FILE {xvc/vivado/out_g1/system.ltx} $dev
refresh_hw_device -update_hw_probes true $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
set probes [get_hw_probes -of_objects $ila]
puts "ILA=$ila PROBES=[llength $probes]"
set_property TRIGGER_COMPARE_VALUE eq1'b1 [lindex $probes 2]
run_hw_ila $ila
puts "ARMED"
after 150000
if {[catch {set data [upload_hw_ila_data $ila]} e]} { puts "UPLOAD_FAIL: $e" } else {
    write_hw_ila_data -force -csv_file xvc/out/ila_vivado.csv $data
    puts "CSV_DONE"
}
catch {close_hw_target}
close_hw_manager
