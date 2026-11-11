open_hw_manager
connect_hw_server -url localhost:3121
current_hw_server localhost:3121
open_hw_target -xvc_url 192.168.1.110:2542
set dev [lindex [get_hw_devices debug_bridge_0] 0]
current_hw_device $dev
set_property PROBES.FILE [file normalize "xvc/out/system.ltx"] $dev
set_property FULL_PROBES.FILE [file normalize "xvc/out/system.ltx"] $dev
refresh_hw_device -update_hw_probes true $dev
puts "=== ilas: [get_hw_ilas -of_objects $dev]"
foreach ila [get_hw_ilas -of_objects $dev] {
  puts "   ILA $ila probes: [get_hw_probes -of_objects $ila]"
}
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
run_hw_ila $ila
wait_on_hw_ila $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file [file normalize "xvc/out/ila_capture.csv"] $data
puts "=== captured, rows: [llength [get_hw_ila_data $data]]"
close_hw_target
close_hw_manager
