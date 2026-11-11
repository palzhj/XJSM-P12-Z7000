open_hw_manager
connect_hw_server -url localhost:3121
foreach t [get_hw_targets] {
  puts "=== TARGET $t"
  current_hw_target $t
  open_hw_target -quiet
  foreach d [get_hw_devices] {
    puts "   DEV $d  IDCODE=[get_property IDCODE $d]"
  }
  close_hw_target
}
close_hw_manager
