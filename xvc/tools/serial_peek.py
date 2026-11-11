#!/usr/bin/env python3
"""Tiny non-blocking serial helper for the board console.

usage: serial_peek.py <dev> [--baud N] [--seconds S] [--send TEXT] [--save FILE]
"""
import argparse, os, select, sys, termios, time, tty


def open_port(dev, baud):
    fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    attrs = termios.tcgetattr(fd)
    speed = getattr(termios, f"B{baud}")
    attrs[0] = 0                      # iflag
    attrs[1] = 0                      # oflag
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0                      # lflag: raw, no echo
    attrs[4] = speed
    attrs[5] = speed
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dev")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=3.0)
    ap.add_argument("--send", default=None, help="text to send, \\r\\n escapes ok")
    ap.add_argument("--save", default=None)
    a = ap.parse_args()

    fd = open_port(a.dev, a.baud)
    if a.send is not None:
        os.write(fd, a.send.encode().decode("unicode_escape").encode())

    deadline = time.time() + a.seconds
    buf = bytearray()
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                chunk = os.read(fd, 4096)
            except BlockingIOError:
                continue
            if not chunk:
                continue
            buf += chunk
            sys.stdout.buffer.write(chunk)
            sys.stdout.flush()
    os.close(fd)

    if a.save:
        with open(a.save, "wb") as f:
            f.write(buf)
    print(f"\n[read {len(buf)} bytes]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
