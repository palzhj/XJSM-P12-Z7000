open_hw_manager
connect_hw_server -url localhost:3121
write_cfgmem -force -format BIN -interface SPIx4 -size 32 \
    -loadbit "up 0x0 [file normalize test_bits/top-with-auto-neg.bit]" \
    [file normalize xvc/out/k7_flash.bin]
puts "BIN_DONE [file size xvc/out/k7_flash.bin]"
close_hw_manager
