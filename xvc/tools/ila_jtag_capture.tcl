open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [lindex [get_hw_targets] 0]
set dev [lindex [get_hw_devices xc7z*] 0]
current_hw_device $dev
set_property PROBES.FILE {xvc/out/system.ltx} $dev
set_property FULL_PROBES.FILE {xvc/out/system.ltx} $dev
refresh_hw_device -update_hw_probes true $dev
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
puts "ILA=$ila"
puts "PROBES=[get_hw_probes -of_objects $ila]"
puts "PROBEPROPS:"
foreach p [get_hw_probes -of_objects $ila] { puts "  $p  = [list_property $p]" }
run_hw_ila $ila
after 3000
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file xvc/out/ila_jtag_jtagm.csv $data
puts "CSV_DONE"
close_hw_target
close_hw_manager
