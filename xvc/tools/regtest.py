import mmap, os, struct
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd,0x2000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=0x43C00000)
def rd(o): return struct.unpack_from("<I",m,o)[0]
def wr(o,v): struct.pack_into("<I",m,o,v)
print("initial:", ["0x%02X=0x%08X"%(o,rd(o)) for o in range(0,0x18,4)])
wr(0x00,0xDEADBEEF); print("LEN rb: 0x%08X"%rd(0x00))
wr(0x04,0x12345678); print("TMS rb: 0x%08X"%rd(0x04))
wr(0x08,0x55AA55AA); print("TDI rb: 0x%08X"%rd(0x08))
wr(0x00,0); print("after clear LEN: 0x%08X"%rd(0x00))
