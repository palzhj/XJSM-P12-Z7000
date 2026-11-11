set ltx [file normalize "xvc/out/system.ltx"]
open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target {localhost:3121/xilinx_tcf/Digilent/210512180081}
open_hw_target
set d [lindex [get_hw_devices xc7z020_1] 0]
current_hw_device $d
refresh_hw_device -update_hw_probes true $d
set_property PROBES.FILE $ltx $d
refresh_hw_device -update_hw_probes true $d
puts "=== ilas: [get_hw_ilas -of_objects $d]"
set ila [lindex [get_hw_ilas -of_objects $d] 0]
puts "=== probes: [get_hw_probes -of_objects $ila]"
run_hw_ila $ila
wait_on_hw_ila $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file [file normalize "xvc/out/ila_capture.csv"] $data
puts "=== CAPTURED"
close_hw_target
close_hw_manager
