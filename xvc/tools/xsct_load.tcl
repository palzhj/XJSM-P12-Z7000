connect
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
stop
puts "STOPPED"
set rc [catch {dow -data /run/media/iheper/a435849f-51ca-4a93-abc2-5d48c0bc1de3/work/XJSM-P12-Z7000/xvc/out/petalinux/image.ub 0x2000000} err]
puts "DOW_RC=$rc ERR=$err"
con
exit
