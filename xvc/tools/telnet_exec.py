#!/usr/bin/env python3
"""telnet_exec.py - run shell commands on the board over telnet (port 23).

SSH on this image rejects root password auth, but telnetd/login(1) accepts it,
so this is the working channel for bring-up scripts.

    ./telnet_exec.py "uname -a" "ls -l /dev/xdevcfg"

Output is printed with the terminal echo and the marker boilerplate stripped.
"""
import os, socket, sys, time

# No credentials in the tree: supply them in the environment, e.g.
#     XVC_PASS='...' ./telnet_exec.py "uname -a"
HOST = os.environ.get("XVC_HOST", "192.168.1.113")
PORT = int(os.environ.get("XVC_TELNET_PORT", "23"))
USER = os.environ.get("XVC_USER", "root")
PASS = os.environ.get("XVC_PASS", "")

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240


class Telnet:
    def __init__(self, host=HOST, port=PORT, user=USER, pw=PASS):
        self.s = socket.create_connection((host, port), timeout=15)
        self.s.settimeout(0.5)
        self.buf = b""
        self.pump(3)
        self._send(user)
        self.pump(2)
        self._send(pw)
        self.pump(3)
        self.read_until(b"# ", 10)
        self.buf = b""

    def _send(self, line):
        self.s.sendall(line.encode() + b"\r\n")

    def _feed(self, data):
        """Strip telnet IAC negotiation, answering with refusals."""
        out = bytearray()
        i = 0
        while i < len(data):
            b = data[i]
            if b == IAC and i + 1 < len(data):
                if i + 2 < len(data) and data[i + 1] in (WILL, WONT, DO, DONT):
                    cmd, opt = data[i + 1], data[i + 2]
                    if cmd == WILL:
                        self.s.sendall(bytes([IAC, DONT, opt]))
                    elif cmd == DO:
                        self.s.sendall(bytes([IAC, WONT, opt]))
                    i += 3
                elif i + 1 < len(data) and data[i + 1] == SB:
                    j = data.find(bytes([IAC, SE]), i)
                    i = (j + 2) if j != -1 else len(data)
                else:
                    i += 2
            else:
                out.append(b)
                i += 1
        return bytes(out)

    def pump(self, sec):
        end = time.time() + sec
        while time.time() < end:
            try:
                d = self.s.recv(8192)
            except socket.timeout:
                continue
            except Exception:
                break
            if not d:
                break
            self.buf += self._feed(d)

    def read_until(self, marker, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if marker in self.buf:
                break
            try:
                d = self.s.recv(8192)
            except socket.timeout:
                continue
            except Exception:
                break
            if not d:
                break
            self.buf += self._feed(d)
        out, self.buf = self.buf, b""
        return out

    def run(self, cmdline, wait=60):
        self.buf = b""
        self._send(cmdline + "; echo __RC=$?__")
        out = self.read_until(b"__RC=", wait)
        time.sleep(0.2)
        self.pump(0.6)
        out += self.buf
        self.buf = b""
        return clean(out.decode("utf-8", "replace"), cmdline)

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def clean(text, cmdline=""):
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = []
    for ln in text.split("\n"):
        s = ln.strip()
        if not s:
            continue
        if s.startswith("echo __RC=") or s == cmdline.strip():
            continue
        if s == cmdline.strip() + "; echo __RC=$?__":
            continue
        if s.startswith("__RC="):
            lines.append("  [exit %s]" % s[5:])
            continue
        lines.append(ln.rstrip())
    return "\n".join(lines)


def main():
    cmds = sys.argv[1:]
    if not cmds:
        print(__doc__)
        return 2
    if not PASS:
        print("set XVC_PASS (and optionally XVC_USER/XVC_HOST) in the environment")
        return 2
    t = Telnet()
    for c in cmds:
        print("=== %s" % c)
        print(t.run(c))
        print()
    t.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
