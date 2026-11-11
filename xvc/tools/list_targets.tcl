open_hw_manager
connect_hw_server -url localhost:3121
puts "=== targets:"
foreach t [get_hw_targets] { puts "  $t" }
close_hw_manager
