import mmap, os, struct, time, sys
fd=os.open("/dev/mem", os.O_RDWR|os.O_SYNC)
m=mmap.mmap(fd,0x2000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=0x43C00000)
def rd(o): return struct.unpack_from("<I",m,o)[0]
def wr(o,v): struct.pack_into("<I",m,o,v)

def xfer(n,tms,tdi):
    wr(0x00,n); wr(0x04,tms&0xFFFFFFFF); wr(0x08,tdi&0xFFFFFFFF); wr(0x10,1)
    g=0
    while rd(0x10):
        g+=1
        if g>2000000: raise RuntimeError("timeout")
    return rd(0x0C)

def run(pairs):
    """pairs: list of (tms,tdi); returns list of tdo bits"""
    out=[]
    i=0
    while i < len(pairs):
        chunk=pairs[i:i+32]
        n=len(chunk)
        tms=0; tdi=0
        for k,(t,d) in enumerate(chunk):
            if t: tms|=1<<k
            if d: tdi|=1<<k
        v=xfer(n,tms,tdi)
        for k in range(n): out.append((v>>k)&1)
        i+=n
    return out

TLR=[(1,0)]*5
def seq_bits(s):
    return [(int(c[0]), int(c[1])) for c in s]

# reset + BYPASS(IR=all ones, 6 bits) + shift pattern
pre = TLR + [(0,0)]                       # TLR -> RTI
    # not used; build explicitly below
def build_ir(value, width=6):
    s = TLR + [(0,0)]                      # RTI
    s += [(1,0),(1,0)]                     # Select-DR, Select-IR
    s += [(0,0)]                           # Capture-IR
    s += [(0,0)]                           # Shift-IR
    s += [(0, ((value>>k)&1)) for k in range(width)]
    s += [(1,0)]                           # Exit1-IR
    s += [(0,0)]                           # Update-IR
    s += [(0,0)]                           # RTI
    return s

def build_dr_shift(pattern, nbits):
    s = [(1,0)]                            # Select-DR
    s += [(0,0)]                           # Capture-DR
    s += [(0,0)]                           # Shift-DR
    s += [(0, ((pattern>>k)&1)) for k in range(nbits)]
    s += [(1,0)]                           # Exit1-DR
    s += [(0,0)]                           # Update-DR
    s += [(0,0)]                           # RTI
    return s

pat = 0xA5A55A5A
nbits = 32
s1 = build_ir(0x3F)                        # BYPASS
tdo1 = run(s1)
print("IR-scan tdo bits:", ''.join(map(str,tdo1)))
s2 = build_dr_shift(pat, nbits)
tdo2 = run(s2)
v = 0
for k in range(nbits):
    v |= tdo2[-nbits+k] << k
print("pattern      = 0x%08X" % pat)
print("dr tdo (last %d bits) = 0x%08X" % (nbits, v))
print("expect (pat>>1)      = 0x%08X" % (pat>>1))
print("all dr bits:", ''.join(map(str,tdo2)))
