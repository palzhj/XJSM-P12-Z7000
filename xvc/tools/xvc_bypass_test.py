#!/usr/bin/env python3
"""Set the JTAG chain to BYPASS, send a known data pattern, and check TDO bit by bit.

With N devices in the chain the BYPASS path length is N, so TDO should be TDI delayed by N bits.
Usage: python3 xvc_bypass_test.py [host] [port] [bits] [ndev]
"""
import socket, struct, sys

host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.113"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 2543
NB   = int(sys.argv[3]) if len(sys.argv) > 3 else 10000
NDEV = int(sys.argv[4]) if len(sys.argv) > 4 else 2

s = socket.create_connection((host, port), 5); s.settimeout(30)
s.sendall(b"getinfo:"); print("getinfo:", s.recv(64).decode().strip())

def rd(n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise RuntimeError("closed")
        b += c
    return b

def shift(nbits, tms_bits, tdi_bits):
    nb = (nbits + 7) // 8
    tms = sum((1 << i) for i, b in enumerate(tms_bits) if b)
    tdi = sum((1 << i) for i, b in enumerate(tdi_bits) if b)
    s.sendall(b"shift:" + struct.pack("<I", nbits)
              + tms.to_bytes(nb, "little") + tdi.to_bytes(nb, "little"))
    return int.from_bytes(rd(nb), "little")

def bits_of(v, n):
    return [(v >> i) & 1 for i in range(n)]

# 1) TLR -> RTI
shift(6, [1,1,1,1,1,0], [0]*6)

# 2) IR scan: SelIR(1,1) CapIR(0) ShiftIR(0) ... 6*NDEV bits (0x3F Bypass) ... Exit1(1) Update(1) RTI(0)
ir_tms = [1,1,0,0] + [0]*(6*NDEV) + [1,1,0]
ir_tdi = [0,0,0,0] + [1]*(6*NDEV) + [0,0,0]   # 0x3F = 111111 (LSB first all ones)
shift(len(ir_tms), ir_tms, ir_tdi)

# 3) DR scan: SelDR(1) CapDR(0) ShiftDR(0) + NB bits + Exit1(1) Update(0) RTI(0)
pre_tms = [1,0,0] + [0]*NB + [1,0,0]
pattern = 0xA5A55A5A
tdi_bits = [(pattern >> (i % 32)) & 1 for i in range(NB)]
tdo = shift(len(pre_tms), pre_tms, tdi_bits)

# extract the data region (NB bits starting at bit 3)
data = [(tdo >> i) & 1 for i in range(len(pre_tms))]
got = data[3:3+NB]
exp = [(0 >> 0) & 1]*NDEV + tdi_bits[:NB-NDEV]   # BYPASS delays by NDEV bits; the first NDEV bits are 0
err = sum(1 for a, b in zip(got, exp) if a != b)
print("bits=%d ndev=%d mismatches=%d" % (NB, NDEV, err))
if err == 0:
    print("BYPASS data integrity OK")
else:
    first = next(i for i,(a,b) in enumerate(zip(got,exp)) if a!=b)
    print("first mismatch position:", first)
s.close()
