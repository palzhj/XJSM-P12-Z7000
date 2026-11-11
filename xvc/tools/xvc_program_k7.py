#!/usr/bin/env python3
"""Standalone 7-series JTAG programming (over XVC) that bypasses Vivado status checks.

Usage: xvc_program_k7.py <host> <port> <bitfile>
Chain order assumed: TDI -> K7 -> A7 -> TDO
"""
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
print("bitstream payload: %d bytes (%.1f Mbit)" % (len(payload), len(payload)*8/1e6))

s = socket.create_connection((host, port), 5); s.settimeout(120)
s.sendall(b"getinfo:"); print("getinfo:", s.recv(64).decode().strip())

def rd(n):
    b = b""
    while len(b) < n:
        c = s.recv(n-len(b))
        if not c: raise RuntimeError("closed")
        b += c
    return b

def shift(nbits, tms_bytes, tdi_bytes):
    nb = (nbits+7)//8
    s.sendall(b"shift:"+struct.pack("<I", nbits)+tms_bytes+tdi_bytes)
    return rd(nb)

def bits_of(vals, nbits_each):
    out = []
    for v in vals:
        out += [(v >> i) & 1 for i in range(nbits_each)]
    return out

def pack(bits):
    v = 0
    for i, b in enumerate(bits):
        if b: v |= 1 << i
    nb = (len(bits)+7)//8
    return v.to_bytes(nb, 'little')

def ir_scan(k7, a7):
    shift(6, pack([1,1,1,1,1,0]), pack([0]*6))
    bits = bits_of([k7, a7], 6)
    tms = [1,1,0,0] + [0]*12 + [1,1,0]
    tdi = [0,0,0,0] + bits + [0,0,0]
    shift(len(tms), pack(tms), pack(tdi))

K7_JPROGRAM, K7_CFG_IN, K7_JSTART, A7_BYPASS = 0x0B, 0x05, 0x0C, 0x3F

print("JPROGRAM ...")
ir_scan(K7_JPROGRAM, A7_BYPASS)
time.sleep(0.2)

print("CFG_IN + streaming payload ...")
ir_scan(K7_CFG_IN, A7_BYPASS)

CHUNK = 60000          # bits per shift
total = len(payload)*8
sent = 0
t0 = time.time()
bitpos = 0
while bitpos < total:
    n = min(CHUNK, total-bitpos)
    nb = (n+7)//8
    # take bits from payload (LSB first per byte)
    start_byte = bitpos // 8
    start_bit = bitpos % 8
    raw = payload[start_byte:start_byte+nb+1]
    bits = []
    for k in range(n):
        byte = raw[(start_bit+k)//8]
        bits.append((byte >> ((start_bit+k) % 8)) & 1)
    tms = [1,0,0] + [0]*n + [1,0,0]
    tdi = [0,0,0] + bits + [0,0,0]
    shift(len(tms), pack(tms), pack(tdi))
    bitpos += n
    if bitpos % 600000 == 0 or bitpos >= total:
        el = time.time()-t0
        print("  %6.1f%%  %.1f Mbit  %.1f s" % (100.0*bitpos/total, bitpos/1e6, el))

print("JSTART ...")
ir_scan(K7_JSTART, A7_BYPASS)
shift(12, pack([0]*12), pack([0]*12))

time.sleep(0.5)
print("Reading status (CFG_OUT) ...")
print("  current status: 0x%08X" % (lambda v: sum(((v>>i)&1)<<i for i in range(32)))(int.from_bytes(shift(38, pack([1,0,0]+[0]*32+[1,0,0]), pack([0]*38)), 'little')))
s.close()
print("DONE")
