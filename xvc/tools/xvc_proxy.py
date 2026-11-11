#!/usr/bin/env python3
"""XVC transparent proxy + packet capture log (no root required).

Vivado connects to <host>:2543, the proxy forwards to the board <board>:2543, and logs
the time, byte counts, command sequence, and close direction of every connection.
"""
import socket, threading, sys, time, struct

LOG = open('xvc/out/proxy.log','w', buffering=1)
BIN = open('xvc/out/proxy.bin','wb', buffering=0)
def out(m):
    print(m, flush=True)
    LOG.write(m + '\n')

LISTEN = ("0.0.0.0", 2543)
BOARD = ("192.168.1.113", 2543)
T0 = time.time()

def ts():
    return "%8.3f" % (time.time() - T0)

def pipe(src, dst, tag, cid):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                out("%s conn%d %s: EOF (peer closed)" % (ts(), cid, tag)); break
            dst.sendall(data)
            BIN.write(struct.pack("<BBI", tag.encode()[0], cid & 0xFF, len(data)))
            BIN.write(data)
            show = data[:32].hex()
            out("%s conn%d %s -> %d bytes %s%s" % (ts(), cid, tag, len(data), show,
                " ..." if len(data) > 32 else ""))
    except Exception as e:
        out("%s conn%d %s: error %s" % (ts(), cid, tag, e))
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except Exception: pass

def handle(c, cid):
    s = socket.create_connection(BOARD, 5)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    out("%s conn%d OPEN  %s -> %s" % (ts(), cid, c.getpeername(), BOARD))
    t1 = threading.Thread(target=pipe, args=(c, s, "C->B", cid), daemon=True)
    t2 = threading.Thread(target=pipe, args=(s, c, "B->C", cid), daemon=True)
    t1.start(); t2.start(); t1.join(); t2.join()
    c.close(); s.close()
    out("%s conn%d CLOSE" % (ts(), cid))

def main():
    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind(LISTEN); ls.listen(8)
    out("proxy %s -> %s" % (LISTEN, BOARD)); sys.stdout.flush()
    cid = 0
    while True:
        c, a = ls.accept(); cid += 1
        threading.Thread(target=handle, args=(c, cid), daemon=True).start()

main()
