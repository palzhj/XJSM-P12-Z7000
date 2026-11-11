#!/usr/bin/env python3
"""Send the IR scan one bit at a time to check whether long shifts are the root cause."""
import socket, struct, sys

host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.113"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 2543

s = socket.create_connection((host, port), 5); s.settimeout(30)
s.sendall(b"getinfo:"); print("getinfo:", s.recv(64).decode().strip())

def rd(n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise RuntimeError("closed")
        b += c
    return b

def shift(nbits, tms, tdi):
    nb = (nbits + 7) // 8
    s.sendall(b"shift:" + struct.pack("<I", nbits) + tms + tdi)
    return rd(nb)

def bit(tms, tdi):
    """Single-bit shift, returns TDO"""
    v = shift(1, bytes([tms & 1]), bytes([tdi & 1]))
    return v[0] & 1

def pack(bits):
    v = 0
    for i, b in enumerate(bits):
        if b: v |= 1 << i
    return v.to_bytes((len(bits)+7)//8, "little")

def tlr_bitwise():
    for t in [1,1,1,1,1,0]:
        bit(t, 0)

def ir_bitwise(ir, nbits=12):
    # 16 TMS=1 bits to enter TLR? Here we start from RTI
    bit(1,0)   # SelDR
    bit(1,0)   # SelIR
    bit(0,0)   # CapIR
    bit(0,0)   # ShiftIR
    bits = []
    for _ in range(nbits//6):
        bits += [(ir >> i) & 1 for i in range(6)]
    for b in bits:
        bit(0, b)
    bit(1,0)   # Exit1IR
    bit(1,0)   # UpdateIR
    bit(0,0)   # RTI

def dr_read(nb_):
    n = 3 + nb_ + 3
    v = int.from_bytes(shift(n, pack([1,0,0]+[0]*nb_+[1,0,0]), pack([0]*n)), "little")
    return [(v >> i) & 1 for i in range(n)]

tlr_bitwise(); b = dr_read(64)
print("TLR(bitwise)   -> A7=0x%08X K7=0x%08X" % (sum(b[3+i]<<i for i in range(32)), sum(b[35+i]<<i for i in range(32))))

for ir in (0x3F, 0x09):
    tlr_bitwise(); ir_bitwise(ir); b = dr_read(64)
    print("IR=0x%02X bitwise -> A7=0x%08X K7=0x%08X" % (ir, sum(b[3+i]<<i for i in range(32)), sum(b[35+i]<<i for i in range(32))))

s.close()
