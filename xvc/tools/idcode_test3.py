import mmap, os, struct, time
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd,0x2000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=0x43C00000)
def rd(o): return struct.unpack_from("<I",m,o)[0]
def wr(o,v): struct.pack_into("<I",m,o,v)
def shift(n,tms,tdi):
    wr(0x00,n); wr(0x04,tms & 0xFFFFFFFF); wr(0x08,tdi & 0xFFFFFFFF); wr(0x10,1)
    time.sleep(0.001)
    g=0
    while rd(0x10):
        g+=1
        if g>1000000: raise RuntimeError("timeout")
    return rd(0x0C)

def revbits(v,n):
    r=0
    for i in range(n):
        r=(r<<1)|((v>>i)&1)
    return r

seq=[1,1,1,1,1, 0, 1,0,0] + [0]*32 + [1]
n=len(seq)
tms=0
for i,b in enumerate(seq):
    if b: tms|=1<<i

def run(tms_lsb, label):
    c1=shift(32, tms_lsb & 0xFFFFFFFF, 0)
    c2=shift(n-32, (tms_lsb>>32) & ((1<<(n-32))-1), 0)
    comb=c1 | ((c2 & ((1<<(n-32))-1))<<32)
    print("%s: c1=0x%08X c2=0x%X w9=0x%08X w10=0x%08X" % (label,c1,c2,(comb>>9)&0xFFFFFFFF,(comb>>10)&0xFFFFFFFF))
    return comb

a=run(tms,"LSB-first")
# reversed bit order interpretation
tms_rev = revbits(tms, n)
b=run(tms_rev,"MSB-first")
# also try reading TDO bit-reversed
print("rev(a)=0x%X rev(b)=0x%X"%(revbits(a,n),revbits(b,n)))
