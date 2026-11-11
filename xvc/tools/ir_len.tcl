open_hw_manager
connect_hw_server -url localhost:3121
foreach tgt [get_hw_targets] {
    if {[catch {open_hw_target $tgt} e]} continue
    set devs [get_hw_devices]
    if {[llength $devs] == 0} { catch {close_hw_target}; continue }
    puts "TARGET $tgt"
    foreach d $devs {
        set ir ""
        catch { set ir [get_property IR_LENGTH $d] }
        set id ""
        catch { set id [get_property IDCODE_HEX $d] }
        puts "  DEV $d  part=[get_property PART $d]  IDCODE=$id  IR_LENGTH=$ir"
    }
    catch { close_hw_target }
}
close_hw_manager
