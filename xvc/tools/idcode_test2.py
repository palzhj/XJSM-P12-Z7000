import mmap, os, struct, time
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd,0x2000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=0x43C00000)
def rd(o): return struct.unpack_from("<I",m,o)[0]
def wr(o,v): struct.pack_into("<I",m,o,v)

def shift(n,tms,tdi,delay=0.002):
    wr(0x00,n); wr(0x04,tms); wr(0x08,tdi)
    wr(0x10,1)
    time.sleep(delay)
    g=0
    while rd(0x10):
        g+=1
        if g>2000000: raise RuntimeError("timeout")
    return rd(0x0C)

seq=[1,1,1,1,1, 0, 1,0,0] + [0]*32 + [1]
n=len(seq)
tms=0
for i,b in enumerate(seq):
    if b: tms|=1<<i

c1=shift(32, tms & 0xFFFFFFFF, 0)
c2=shift(n-32, (tms>>32) & ((1<<(n-32))-1), 0)
comb=c1 | ((c2 & ((1<<(n-32))-1))<<32)
print("c1=0x%08X c2=0x%X"%(c1,c2))
print("combined=0x%X"%comb)
print("window@9=0x%08X"%((comb>>9)&0xFFFFFFFF))
print("expect 0x23727093")
# repeat to see if stable
for k in range(3):
    a=shift(32,0,0,0.005); b=shift(32,0,0,0.005)
    print("idle read %d: 0x%08X 0x%08X"%(k,a,b))
