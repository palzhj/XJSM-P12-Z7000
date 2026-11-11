set ltx [file normalize "xvc/out/system.ltx"]
set bit [file normalize "xvc/out/system_wrapper.bit"]

open_hw_manager
connect_hw_server -url localhost:3121

# 1) program the PL over the local Digilent cable (also resets the debug hub)
current_hw_target {localhost:3121/xilinx_tcf/Digilent/210512180081}
open_hw_target
set jdev [lindex [get_hw_devices xc7z020_1] 0]
current_hw_device $jdev
create_hw_bitstream -hw_device $jdev $bit
program_hw_devices $jdev
close_hw_target

# 2) talk to the same design through XVC
open_hw_target -xvc_url 192.168.1.110:2542
set dev [lindex [get_hw_devices] 0]
puts "=== XVC device: $dev IDCODE=[get_property IDCODE $dev]"
current_hw_device $dev
set_property PROBES.FILE $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev
refresh_hw_device -update_hw_probes true $dev
puts "=== ilas: [get_hw_ilas -of_objects $dev]"
set ila [lindex [get_hw_ilas -of_objects $dev] 0]
puts "=== probes: [get_hw_probes -of_objects $ila]"
run_hw_ila $ila
wait_on_hw_ila $ila
set data [upload_hw_ila_data $ila]
write_hw_ila_data -force -csv_file [file normalize "xvc/out/ila_capture.csv"] $data
puts "=== ILA_CAPTURED"
close_hw_target
close_hw_manager
