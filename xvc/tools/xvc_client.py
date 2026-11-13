#!/usr/bin/env python3
"""xvc_client.py - minimal XVC 1.0 client, to test port 2543 without Vivado.

Sends the same IDCODE sequence jtag_idcode.c uses, so the two answers can be
compared: one goes through the XVC server, the other straight at the registers.

    ./xvc_client.py [host] [port]
"""
import socket
import sys


class XVC:
    def __init__(self, host, port, timeout=5.0):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.settimeout(timeout)

    def _send(self, data):
        self.s.sendall(data)

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            d = self.s.recv(n - len(buf))
            if not d:
                raise RuntimeError("peer closed after %d/%d bytes" % (len(buf), n))
            buf += d
        return buf

    def getinfo(self):
        self._send(b"getinfo:")
        buf = b""
        while not buf.endswith(b"\n"):
            buf += self.s.recv(1)
        return buf.decode(errors="replace").strip()

    def settck(self, period_ns):
        self._send(b"settck:%d" % period_ns)
        return int.from_bytes(self._recv(4), "little")

    def shift(self, nbits, tdi, tms):
        nb = (nbits + 7) // 8
        tdi = (tdi + bytes(nb))[:nb]
        tms = (tms + bytes(nb))[:nb]
        msg = b"shift:%d" % nbits
        msg += bytes(reversed(tdi)).hex().upper().encode()
        msg += bytes(reversed(tms)).hex().upper().encode()
        self._send(msg)
        rsp = self._recv(2 * nb).decode(errors="replace")
        return bytes(reversed(bytes.fromhex(rsp))), nb

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def bits_to_bytes(seq):
    b = bytearray((len(seq) + 7) // 8)
    for i, v in enumerate(seq):
        if v:
            b[i // 8] |= 1 << (i % 8)
    return bytes(b)


def main():
    host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.113"
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 2543
    x = XVC(host, port)
    print("getinfo  :", x.getinfo())
    print("settck   : %d ns" % x.settck(100))

    # 5x TMS=1 (reset), 0 (RTI), 1,0,0 (Select-DR, Capture-DR, Shift-DR),
    # 32 clocks TMS=0 shifting the IDCODE out, then 1 (Exit1-DR)
    seq = [1] * 5 + [0] + [1, 0, 0] + [0] * 32 + [1]
    n = len(seq)
    rem = n - 32

    tdo1, _ = x.shift(32, bytes(4), bits_to_bytes(seq[:32]))
    tdo2, _ = x.shift(rem, bytes((rem + 7) // 8), bits_to_bytes(seq[32:]))

    c1 = int.from_bytes(tdo1, "little")
    c2 = int.from_bytes(tdo2, "little") & ((1 << rem) - 1)
    comb = c1 | (c2 << 32)
    print("tdo32    : 0x%08X" % c1)
    print("window@9 : 0x%08X   (register-level read gave 0x00256093)" % ((comb >> 9) & 0xFFFFFFFF))
    x.close()
    print("XVC_CLIENT_OK")


if __name__ == "__main__":
    main()
