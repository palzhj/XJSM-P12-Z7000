# Export LTX + XSA from an already-implemented project run.
set script_dir [file dirname [file normalize [info script]]]
open_project [file join $script_dir work xvc.xpr]
open_run impl_1
file mkdir [file join $script_dir out]
write_debug_probes -force [file join $script_dir out system.ltx]
write_hw_platform -fixed -include_bit -force [file join $script_dir out system.xsa]
puts "EXPORT_DONE"
