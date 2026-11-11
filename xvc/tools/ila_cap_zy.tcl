open_hw_manager
connect_hw_server -url localhost:3121
set tgt localhost:3121/xilinx_tcf/Digilent/210512180081
if {[catch {open_hw_target $tgt} e]} { puts "ERR open: $e"; close_hw_manager; exit 1 }
set dev [lindex [get_hw_devices xc7z020*] 0]
puts "TARGET: $dev"
set_property PROBES.FILE {xvc/vivado/out_g1/system.ltx} $dev
set_property FULL_PROBES.FILE {xvc/vivado/out_g1/system.ltx} $dev
refresh_hw_device -update_hw_probes true $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
set probes [get_hw_probes -of_objects $ila]
puts "PROBES: $probes"
set tms_p [lindex $probes 1]
set_property TRIGGER_COMPARE_VALUE eq1'b1 $tms_p
run_hw_ila $ila
puts "ARMED"
after 70000
if {[catch {set data [upload_hw_ila_data $ila]} e]} { puts "UPLOAD FAIL: $e" } else {
    write_hw_ila_data -force -csv_file xvc/out/ila_vivado.csv $data
    puts "CSV_DONE"
}
catch {close_hw_target}
close_hw_manager
