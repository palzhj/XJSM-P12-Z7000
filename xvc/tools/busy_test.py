import mmap, os, struct, time
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd,0x2000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=0x43C00000)
def rd(o): return struct.unpack_from("<I",m,o)[0]
def wr(o,v): struct.pack_into("<I",m,o,v)
wr(0x00,32); wr(0x04,0xFFFFFFFF); wr(0x08,0)
wr(0x10,1)
vals=[]
for i in range(30):
    vals.append(rd(0x10))
print("ctrl after start:", vals)
print("tdo=0x%08X"%rd(0x0C))
# and with a delay
wr(0x00,32); wr(0x04,0); wr(0x08,0); wr(0x10,1)
time.sleep(0.0002)
print("ctrl after 200us:", rd(0x10), "tdo=0x%08X"%rd(0x0C))
