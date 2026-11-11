import mmap, os, struct
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd,0x2000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=0x43C00000)
def rd(o): return struct.unpack_from("<I",m,o)[0]
def wr(o,v): struct.pack_into("<I",m,o,v)
def shift(n,tms,tdi):
    wr(0x00,n); wr(0x04,tms); wr(0x08,tdi); wr(0x10,1)
    g=0
    while rd(0x10):
        g+=1
        if g>1000000: raise RuntimeError("timeout")
    return rd(0x0C)

seq=[1,1,1,1,1, 0, 1,0,0] + [0]*32 + [1]
n=len(seq)
tms=0
for i,b in enumerate(seq):
    if b: tms|=1<<i

c1=shift(32, tms & 0xFFFFFFFF, 0)
print("chunk1: tdo=0x%08X"%c1)
rem=n-32
c2=shift(rem, (tms>>32) & ((1<<rem)-1), 0)
print("chunk2: tdo=0x%X"%c2)
comb = c1 | ((c2 & ((1<<rem)-1)) << 32)
print("combined=0x%X"%comb)
print("window@9=0x%08X"%((comb>>9)&0xFFFFFFFF))
print("window@10=0x%08X"%((comb>>10)&0xFFFFFFFF))
