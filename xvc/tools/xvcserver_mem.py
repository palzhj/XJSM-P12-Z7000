#!/usr/bin/env python3
"""
xvcserver_mem.py - XVC 1.0 server for the Debug Bridge, using /dev/mem.

Bring-up variant of xvcserver.c: no UIO device node and no cross compiler are
needed, which makes it usable on a stock vendor image (e.g. the ALINX demo
rootfs with CONFIG_STRICT_DEVMEM=n).

    python3 xvcserver_mem.py            # default 0x43C00000, port 2542
    python3 xvcserver_mem.py -a 0x43C00000 -p 2542 -v

Registers (Debug Bridge, AXI to BSCAN mode):
    0x00 len   0x04 tms   0x08 tdi   0x0C tdo   0x10 ctrl(bit0 start)
"""
import argparse
import mmap
import os
import select
import socket
import struct
import sys
import time

LEN, TMS, TDI, TDO, CTRL = 0x00, 0x04, 0x08, 0x0C, 0x10
XVC_MAX_BITS = 2048


class Bridge:
    def __init__(self, addr, page=0x1000):
        self.tck_ns = 1000          # TCK period, updated by settck
        self.fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
        base = addr & ~(page - 1)
        self.off = addr - base
        self.mem = mmap.mmap(self.fd, page + 0x1000, mmap.MAP_SHARED,
                             mmap.PROT_READ | mmap.PROT_WRITE, offset=base)

    def rd(self, reg):
        return struct.unpack_from("<I", self.mem, self.off + reg)[0]

    def wr(self, reg, val):
        struct.pack_into("<I", self.mem, self.off + reg, val & 0xFFFFFFFF)

    def shift(self, nbits, tms, tdi):
        self.wr(LEN, nbits)
        self.wr(TMS, tms)
        self.wr(TDI, tdi)
        self.wr(CTRL, 1)
        # CTRL is a write-only strobe here: it reads back 0 immediately, so the
        # shift has to be given time to finish before TDO is valid.
        time.sleep(nbits * self.tck_ns * 1e-9 + 200e-6)
        return self.rd(TDO)


def serve(conn, br, verbose):
    def readn(n):
        buf = b""
        while len(buf) < n:
            try:
                chunk = conn.recv(n - len(buf))
            except socket.timeout:
                raise ConnectionError("idle timeout")
            if not chunk:
                raise ConnectionError("peer closed")
            buf += chunk
        return buf

    while True:
        cmd = readn(2)
        if cmd == b"ge":
            readn(6)
            conn.sendall(("xvcServer_v1.0:%d\n" % XVC_MAX_BITS).encode())
        elif cmd == b"se":
            rest = readn(9)                    # "ttck:" + 4-byte LE period (ns)
            period = struct.unpack("<I", rest[5:9])[0]
            if period:
                br.tck_ns = period
            conn.sendall(rest[5:9])            # echo the period back (XVC 1.0)
        elif cmd == b"sh":
            readn(4)
            nbits = struct.unpack("<I", readn(4))[0]
            if nbits <= 0 or nbits > XVC_MAX_BITS:
                raise ValueError("bad length %d" % nbits)
            nbytes = (nbits + 7) // 8
            payload = readn(nbytes * 2)
            tms_b, tdi_b = payload[:nbytes], payload[nbytes:]
            out = bytearray()
            left, bits = nbytes, nbits
            i = 0
            while left > 0:
                n = 4 if left >= 4 else left
                tms = int.from_bytes(tms_b[i:i + n], "little")
                tdi = int.from_bytes(tdi_b[i:i + n], "little")
                nb = 32 if n == 4 else bits
                tdo = br.shift(nb, tms, tdi)
                out += tdo.to_bytes(4, "little")[:n]
                left -= n
                bits -= nb
                i += n
            conn.sendall(bytes(out))
            if verbose:
                print("shift %d bits ok" % nbits)
        else:
            raise ValueError("bad command %r" % cmd)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-a", "--addr", default="0x43C00000")
    ap.add_argument("-p", "--port", type=int, default=2542)
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    br = Bridge(int(a.addr, 0))
    print("debug bridge @ %s, ctrl=0x%08x" % (a.addr, br.rd(CTRL)))

    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("0.0.0.0", a.port))
    s.listen(1)
    print("xvcserver (mem) listening on %d" % a.port)
    sys.stdout.flush()

    while True:
        conn, peer = s.accept()
        conn.settimeout(120)          # drop stale clients, XVC is single-session
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        print("connection from %s:%d" % peer)
        try:
            serve(conn, br, a.verbose)
        except Exception as e:
            print("connection closed: %s" % e)
        finally:
            conn.close()


if __name__ == "__main__":
    main()
