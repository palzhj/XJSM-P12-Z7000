connect
puts "TARGETS: [targets]"
set rc [catch {dow -data /etc/hostname 0x2000000} err]
puts "DOW_RC=$rc ERR=$err"
exit
