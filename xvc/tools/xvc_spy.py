#!/usr/bin/env python3
"""xvc_spy.py - log what hw_server actually sends to an XVC endpoint.

Listens on 127.0.0.1:9999, answers getinfo/settck enough to keep hw_server
going, then dumps the raw bytes of the next command so the wire dialect
(ASCII XVC vs the repo's binary variant) can be read off directly.
"""
import socket
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 9999

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(2)
print("listening on %d" % PORT, flush=True)

conn, addr = srv.accept()
conn.settimeout(20)
print("connection from %s" % (addr,), flush=True)

INFO = b"xvcServer_v1.0:4194304\n"


def rd(n, tmo=20):
    conn.settimeout(tmo)
    buf = b""
    while len(buf) < n:
        d = conn.recv(n - len(buf))
        if not d:
            break
        buf += d
    return buf


for step in range(8):
    head = rd(2)
    if not head:
        print("client closed", flush=True)
        break
    if head == b"ge":
        rest = rd(6)
        print("getinfo  <- %r%r" % (head, rest), flush=True)
        conn.sendall(INFO)
    elif head.startswith(b"se"):
        rest = rd(9)
        print("settck   <- %r%r  (hex %s)" % (head, rest, rest.hex()), flush=True)
        conn.sendall(rest[5:9] if len(rest) >= 9 else b"\x64\x00\x00\x00")
    else:
        rest = rd(10)
        print("OTHER    <- %r%r" % (head, rest), flush=True)
        print("   head=%r  next10=%r  (hex %s)" % (head, rest, rest.hex()), flush=True)
        if len(rest) >= 10:
            print("   as ASCII digits?: %r" % rest[:4], flush=True)
            print("   as binary uint32: %d" % int.from_bytes(rest[:4], "little"), flush=True)
        break

conn.close()
print("SPY_DONE", flush=True)
