import mmap, os, struct, time
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd,0x2000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=0x43C00000)
def rd(o): return struct.unpack_from("<I",m,o)[0]
def wr(o,v): struct.pack_into("<I",m,o,v)
def shift(n,tms,tdi,delay):
    wr(0x00,n); wr(0x04,tms&0xFFFFFFFF); wr(0x08,tdi&0xFFFFFFFF); wr(0x10,1)
    time.sleep(delay)
    return rd(0x0C)
for d in (0, 5e-6, 20e-6, 100e-6):
    rs=[shift(32,0xFFFFFFFF,0,d) for _ in range(5)]
    print("delay %6.0f us: "%(d*1e6), ["0x%08X"%r for r in rs])
# IDCODE read with 100us delay, split 32+10
seq=[1,1,1,1,1,0,1,0,0]+[0]*32+[1]
tms=0
for i,b in enumerate(seq):
    if b: tms|=1<<i
c1=shift(32,tms&0xFFFFFFFF,0,100e-6)
c2=shift(10,(tms>>32)&0x3FF,0,100e-6)
comb=c1|((c2&0x3FF)<<32)
print("idcode read: c1=0x%08X c2=0x%X w9=0x%08X"%(c1,c2,(comb>>9)&0xFFFFFFFF))
