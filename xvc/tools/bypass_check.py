#!/usr/bin/env python3
"""BYPASS penetration test: set both devices to BYPASS and check for bit errors from TDI->TDO.

Usage: bypass_check.py [host] [port] [N]
Expectation: TDO data region = TDI delayed by 2 bits (2 devices in the chain), first 2 bits are 0.
"""
import socket, struct, sys, random

host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.113"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 2543
N    = int(sys.argv[3]) if len(sys.argv) > 3 else 2000

s = socket.create_connection((host, port), 5); s.settimeout(120)
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

def pack(bits):
    v = 0
    for i, b in enumerate(bits):
        if b: v |= 1 << i
    return v.to_bytes((len(bits)+7)//8, "little")

# TLR -> RTI
shift(6, pack([1,1,1,1,1,0]), pack([0]*6))
# IR: SelIR, CapIR, ShiftIR + 12 bit BYPASS + Exit1IR, UpdateIR, RTI
bits = [1]*12
tms = [1,1,0,0] + [0]*12 + [1,1,0]
tdi = [0,0,0,0] + bits + [0,0,0]
shift(len(tms), pack(tms), pack(tdi))

# DR: SelDR, CapDR, ShiftDR + N bits + Exit1DR, UpdateDR, RTI
random.seed(1234)
pat = [random.randint(0,1) for _ in range(N)]
tms = [1,0,0] + [0]*N + [1,0,0]
tdi = [0,0,0] + pat + [0,0,0]
v = int.from_bytes(shift(len(tms), pack(tms), pack(tdi)), "little")
got = [(v >> i) & 1 for i in range(len(tms))]

data = got[2:2+N]
exp  = [0,0] + pat[:N-2]
err  = sum(1 for a,b in zip(data, exp) if a != b)
print("N=%d  mismatched bits in data region = %d" % (N, err))
if err:
    first = next(i for i,(a,b) in enumerate(zip(data,exp)) if a!=b)
    print("  first mismatch position:", first)
    print("  TDO[0:32]:", ''.join(map(str,data[:32])))
    print("  TDI[0:32]:", ''.join(map(str,pat[:32])))
else:
    print("  ✅ TDI->TDO has no bit errors")
s.close()
