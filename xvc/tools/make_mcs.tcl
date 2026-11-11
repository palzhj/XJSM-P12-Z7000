open_hw_manager
connect_hw_server -url localhost:3121
# Generate the MCS (32 MB = 256 Mbit, SPIx4)
write_cfgmem -force -format MCS -interface SPIx4 -size 32 \
    -loadbit "up 0x0 [file normalize test_bits/top-with-auto-neg.bit]" \
    [file normalize xvc/out/k7_flash.mcs]
puts "MCS_DONE [file size xvc/out/k7_flash.mcs]"
close_hw_manager
