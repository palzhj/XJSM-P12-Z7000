#!/usr/bin/env python3
"""XVC loopback self-test: run it after fitting a jumper wire between J20-5 (TDI) and J20-6 (TDO).

Usage: python3 xvc_loopback.py [host] [port] [pattern]
Expected: readback TDO = the transmitted TDI pattern delayed by one TCK (in ShiftDR, TDO outputs the previous bit).
"""
import socket, struct, sys

host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.113"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 2543
pat = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0xA5A5_5A5A

def rd(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise RuntimeError("closed")
        b += c
    return b

def shift(s, nbits, tms, tdi):
    nb = (nbits + 7) // 8
    s.sendall(b"shift:" + struct.pack("<I", nbits)
              + tms.to_bytes(nb, "little") + tdi.to_bytes(nb, "little"))
    return int.from_bytes(rd(s, nb), "little")

s = socket.create_connection((host, port), 5)
s.settimeout(5)
s.sendall(b"getinfo:"); print("getinfo:", s.recv(64).decode().strip())
s.sendall(b"settck:" + struct.pack("<I", 1000)); print("settck echo:", struct.unpack("<I", rd(s, 4))[0])

# TLR(5) -> RTI -> SelDR -> CapDR -> ShiftDR
pre = [1,1,1,1,1,0,1,0,0]
tms = sum((1 << i) for i, b in enumerate(pre) if b)
shift(s, 9, tms, 0)

tdo = shift(s, 32, 0, pat)
print("sent TDI = 0x%08X" % pat)
print("read TDO = 0x%08X" % tdo)
print("expected (loopback, 1 bit delay) = 0x%08X" % ((pat >> 1) | ((pat & 1) << 31)))
print("match:", tdo == ((pat >> 1) | ((pat & 1) << 31)))
s.close()
