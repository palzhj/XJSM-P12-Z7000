#!/usr/bin/env python3
"""Minimal raw-socket SCPI client for the N6705C (no pyvisa needed)."""
import socket, sys, time

HOST, PORT = "192.168.1.88", 5025

def connect(host=HOST, port=PORT, timeout=10.0):
    s = socket.create_connection((host, port), timeout=timeout)
    s.settimeout(timeout)
    time.sleep(0.25)                      # instrument needs a moment after accept
    s.sendall(b"*CLS\n")                  # drop stale error/status state
    return s

def ask(s, cmd, timeout=10.0):
    s.settimeout(timeout)
    s.sendall((cmd + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf.decode(errors="replace").strip()

def write(s, cmd):
    s.sendall((cmd + "\n").encode())

def run(cmds):
    s = connect()
    try:
        for c in cmds:
            print(f"{c:<34} -> {ask(s, c) if c.endswith('?') else '(write)'}")
    finally:
        s.close()

if __name__ == "__main__":
    run(sys.argv[1:])
