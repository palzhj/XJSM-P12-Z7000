#!/usr/bin/env python3
"""Standalone 7-series programmer (fixed IR alignment: 3 leading zeros + 13-bit pattern)."""
import socket, struct, sys, time

host, port, bitfile = sys.argv[1], int(sys.argv[2]), sys.argv[3]

def parse_bit(path):
    d = open(path, 'rb').read()
    i = 13
    while i < len(d):
        c = chr(d[i]); i += 1
        if c == 'e':
            ln = int.from_bytes(d[i:i+4], 'big'); i += 4
            return d[i:i+ln]
        ln = int.from_bytes(d[i:i+2], 'big'); i += 2 + ln
    raise RuntimeError("bad bit file")

payload = parse_bit(bitfile)
total = len(payload) * 8
print("payload: %d bytes (%.1f Mbit)" % (len(payload), total/1e6))

s = socket.create_connection((host, port), 5); s.settimeout(120)
s.sendall(b"getinfo:"); print("getinfo:", s.recv(64).decode().strip())

def rd(n):
    b = b""
    while len(b) < n:
        c = s.recv(n-len(b))
        if not c: raise RuntimeError("closed")
        b += c
    return b

def shift(nbits, tms_b, tdi_b):
    nb = (nbits+7)//8
    s.sendall(b"shift:"+struct.pack("<I", nbits)+tms_b.ljust(nb,b"\0")[:nb]+tdi_b.ljust(nb,b"\0")[:nb])
    return rd(nb)

def pack(bits):
    v = 0
    for i, b in enumerate(bits):
        if b: v |= 1 << i
    return v.to_bytes((len(bits)+7)//8, 'little')

def tlr():
    shift(6, pack([1,1,1,1,1,0]), pack([0]*6))

def ir_scan(ir):
    bits = [(ir >> (i % 6)) & 1 for i in range(13)]
    tms = [1,1,0,0] + [0]*13 + [1,1,0]
    tdi = [0,0,0] + bits + [0,0,0,0]
    shift(len(tms), pack(tms), pack(tdi))

def dr_shift(bitlist):
    n = len(bitlist)
    tms = [1,0,0] + [0]*n + [1,0,0]
    tdi = [0,0,0] + bitlist + [0,0,0]
    shift(len(tms), pack(tms), pack(tdi))

print("JPROGRAM...")
tlr(); ir_scan(0x0B); time.sleep(0.3)

print("CFG_IN...")
ir_scan(0x05)

CH = 60000
pos = 0
t0 = time.time()
while pos < total:
    n = min(CH, total-pos)
    bits = []
    for k in range(n):
        bp = pos + k
        bits.append((payload[bp >> 3] >> (bp & 7)) & 1)
    dr_shift(bits)
    pos += n
    if pos % 1200000 < CH:
        print("  %.1f%%  %.1f Mbit  %.1fs" % (100.0*pos/total, pos/1e6, time.time()-t0))

print("JSTART...")
ir_scan(0x0C)
shift(12, pack([0]*12), pack([0]*12))
time.sleep(0.5)
print("done in %.1f s" % (time.time()-t0))
s.close()
