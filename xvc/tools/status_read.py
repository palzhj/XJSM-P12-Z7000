#!/usr/bin/env python3
"""Read the K7 configuration status: check the chain first, then read CFG_OUT."""
import socket, struct, sys, time

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

def pack(bits):
    v = 0
    for i, b in enumerate(bits):
        if b: v |= 1 << i
    return v.to_bytes((len(bits) + 7) // 8, "little")

def bits_of(v, n):
    return [(v >> i) & 1 for i in range(n)]

def tlr():
    shift(6, pack([1,1,1,1,1,0]), pack([0]*6))

def ir_scan(k7, a7):
    # TDI order: the TDI side of the chain receives first -> K7 first
    bits = bits_of(k7, 6) + bits_of(a7, 6)
    tms = [1,1,0,0] + [0]*12 + [1,1,0]
    shift(len(tms), pack(tms), pack([0,0,0,0] + bits + [0,0,0]))

def dr_read(nbits):
    n = 3 + nbits + 3
    tms = [1,0,0] + [0]*nbits + [1,0,0]
    v = int.from_bytes(shift(n, pack(tms), pack([0]*n)), "little")
    return bits_of(v, n)

# --- 1) verify the chain (no IR write; IDCODE is the default after TLR) ---
tlr()
b = dr_read(64)
a7 = sum(b[3+i] << i for i in range(32))
k7 = sum(b[3+32+i] << i for i in range(32))
print("chain: A7=0x%08X  K7=0x%08X" % (a7, k7))

# --- 2) read CFG_OUT (K7=0x04, A7=BYPASS) ---
tlr()
ir_scan(0x04, 0x3F)
b = dr_read(40)
# TDO gives A7's single BYPASS bit first, then K7's 32-bit status
st = sum(b[4+i] << i for i in range(32))
print("CFG_OUT before JPROGRAM: 0x%08X  (raw[3:8]=%s)" % (st, ''.join(map(str,b[3:9]))))

# --- 3) read again after JPROGRAM ---
tlr()
ir_scan(0x0B, 0x3F)
time.sleep(0.3)
tlr()
ir_scan(0x04, 0x3F)
b = dr_read(40)
st2 = sum(b[4+i] << i for i in range(32))
print("CFG_OUT after  JPROGRAM: 0x%08X" % st2)
s.close()
