#!/usr/bin/env python3
"""xvc_binary_client.py - binary XAPP1251 XVC client.

For the single-channel DMA server (`xvcserver_dma -m`), which speaks the real
XVC wire protocol: 8-byte "getinfo:", "settck:" + u32, "shift:" + u32 + TMS
bytes + TDI bytes -> TDO bytes. (xvc_client.py in this directory speaks the
ASCII variant used by the earlier debug servers and cannot talk to it.)

    ./xvc_binary_client.py [host] [port] idcode
    ./xvc_binary_client.py [host] [port] bulk [bits]

`bulk` puts the TAP in Shift-DR and then shifts `bits` clocks with TMS=0, which
is the run the server routes to the AXI DMA (threshold 8192 bits). It reports
the achieved rate, so the DMA path can be measured through the actual protocol.
"""
import socket
import struct
import sys
import time


class XVC:
    def __init__(self, host, port=2543, timeout=120.0):
        self.s = socket.create_connection((host, port), timeout=5.0)
        self.s.settimeout(timeout)

    def recv(self, n):
        buf = b""
        while len(buf) < n:
            d = self.s.recv(n - len(buf))
            if not d:
                raise RuntimeError("peer closed after %d/%d" % (len(buf), n))
            buf += d
        return buf

    def getinfo(self):
        self.s.sendall(b"getinfo:")
        buf = b""
        while not buf.endswith(b"\n"):
            d = self.s.recv(1)
            if not d:
                raise RuntimeError("peer closed during getinfo")
            buf += d
        return buf.decode(errors="replace").strip()

    def settck(self, period_ns):
        self.s.sendall(b"settck:" + struct.pack("<I", period_ns))
        return struct.unpack("<I", self.recv(4))[0]

    def shift(self, nbits, tms, tdi):
        nb = (nbits + 7) // 8
        tms = (tms + bytes(nb))[:nb]
        tdi = (tdi + bytes(nb))[:nb]
        self.s.sendall(b"shift:" + struct.pack("<I", nbits) + tms + tdi)
        return self.recv(nb)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def pack_bits(seq):
    """list of 0/1 -> bytes, first bit = bit0 of byte0 (Xilinx order)."""
    out = bytearray((len(seq) + 7) // 8)
    for i, v in enumerate(seq):
        if v:
            out[i >> 3] |= 1 << (i & 7)
    return bytes(out)


def unpack_bits(buf, nbits):
    return [(buf[i >> 3] >> (i & 7)) & 1 for i in range(nbits)]


def window(bits, start, n=32):
    v = 0
    for i in range(n):
        if start + i < len(bits) and bits[start + i]:
            v |= 1 << i
    return v


def cmd_idcode(x):
    # same sequence as jtag_idcode.c: 5 x TMS=1 (reset), 0 (run/idle),
    # 1,0,0 (select/capture/shift DR), 32 x 0 (shift), 1 (exit1)
    seq = []
    seq += [1] * 5
    seq += [0]
    seq += [1, 0, 0]
    seq += [0] * 32
    seq += [1]
    n = len(seq)
    tdo = x.shift(n, pack_bits(seq), bytes((n + 7) // 8))
    bits = unpack_bits(tdo, n)
    print("tdo bits: %s" % "".join(str(b) for b in bits))
    for off in (9, 10, 11):
        print("window@%d = 0x%08X" % (off, window(bits, off)))
    val = window(bits, 10)
    print("IDCODE candidate: 0x%08X %s" %
          (val, "(plausible)" if val not in (0, 0xFFFFFFFF) else "(TDO stuck)"))


def cmd_bulk(x, nbits):
    # 5x1 reset, 0 run/idle, 1,0,0 select/capture/shift DR, then nbits-10 zeros
    nav = [1] * 5 + [0] + [1, 0, 0]
    total = len(nav) + (nbits - len(nav))
    tms = pack_bits(nav + [0] * (total - len(nav)))
    tdi = bytes([0xAA]) * ((total + 7) // 8)
    print("bulk: %d bits, TMS=0 run of %d (DMA threshold 8192)" %
          (total, total - len(nav)))
    t0 = time.time()
    tdo = x.shift(total, tms, tdi)
    dt = time.time() - t0
    ones = sum(bin(b).count("1") for b in tdo)
    uniq = len(set(tdo))
    print("bulk: %.4f s -> %.2f Mbit/s  (%.2f Mbit/s at the 10.00 ceiling)" %
          (dt, total / dt / 1e6, total / dt / 1e6))
    print("bulk: tdo %d bytes, %d ones, %d distinct byte values, first %s" %
          (len(tdo), ones, uniq, tdo[:8].hex()))
    if uniq == 1:
        print("bulk: WARNING tdo is a constant byte - no device answering?")
    return dt, total


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.113"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 2543
    what = sys.argv[3] if len(sys.argv) > 3 else "idcode"
    x = XVC(host, port)
    try:
        print("getinfo : %s" % x.getinfo())
        print("settck  : %d ns" % x.settck(100))
        if what == "idcode":
            cmd_idcode(x)
        elif what == "bulk":
            nbits = int(sys.argv[4]) if len(sys.argv) > 4 else 262144
            cmd_bulk(x, nbits)
        else:
            print("unknown mode %r" % what)
            return 1
    finally:
        x.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
