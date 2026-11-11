open_hw_manager
connect_hw_server -url localhost:3121
current_hw_target {localhost:3121/xilinx_tcf/Digilent/210512180081}
open_hw_target
set d [lindex [get_hw_devices xc7z020_1] 0]
refresh_hw_device -quiet $d
foreach p [list_property $d] {
  if {[string match -nocase "*done*" $p] || [string match -nocase "*pcap*" $p] || [string match -nocase "*program*" $p]} {
    puts "   $p = [get_property $p $d]"
  }
}
close_hw_target
close_hw_manager
