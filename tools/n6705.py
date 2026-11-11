#!/usr/bin/env python3
"""Keysight N6705C helper over raw SCPI (port 5025). No pyvisa required.

Usage:
    python3 tools/n6705.py status                 # one snapshot of all 4 channels
    python3 tools/n6705.py log 10 0.5             # 10 s log @ 2 Hz -> CSV
    python3 tools/n6705.py set 1 5.0 1.0          # CH1 = 5.0 V, 1.0 A limit (output left as-is)
    python3 tools/n6705.py on 1 / off 1           # output control (asks nothing: be careful)

Notes on this instrument (MY56001992, FW E.01.06.2838):
  * SYST:CHAN:CAT? and FUNC? are NOT supported -> we probe channels 1..4 directly.
  * A query that is unsupported does not answer at all (socket timeout), so every
    query here reconnects; never assume a missing reply means "0".
"""
import socket
import sys
import time
from pathlib import Path

HOST, PORT = "192.168.1.88", 5025
CHANNELS = (1, 2, 3, 4)


def connect(timeout=10.0):
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    s.settimeout(timeout)
    time.sleep(0.25)          # instrument needs a moment after accept()
    return s


def ask(sock, cmd, timeout=10.0):
    sock.settimeout(timeout)
    sock.sendall((cmd + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = sock.recv(4096)
        if not chunk:
            break
        buf += chunk
    return buf.decode(errors="replace").strip()


def write(sock, cmd):
    sock.sendall((cmd + "\n").encode())


def query(cmd, timeout=10.0):
    """Single-shot query on a fresh connection (robust against timeouts)."""
    s = connect(timeout)
    try:
        return ask(s, cmd, timeout)
    finally:
        s.close()


def ident():
    return query("*IDN?")


def status():
    rows = []
    s = connect()
    try:
        for n in CHANNELS:
            out = ask(s, f"OUTP? (@{n})")
            vset = float(ask(s, f"VOLT? (@{n})"))
            iset = float(ask(s, f"CURR? (@{n})"))
            v = float(ask(s, f"MEAS:VOLT? (@{n})", timeout=20))
            i = float(ask(s, f"MEAS:CURR? (@{n})", timeout=20))
            rows.append(dict(ch=n, on=out.strip() == "1", vset=vset, iset=iset,
                             v=v, i=i, p=v * i))
    finally:
        s.close()
    return rows


def fmt(rows):
    out = [f"{'ch':>2} {'OUT':>3} {'Vset':>7} {'Iset':>6} {'Vmeas':>9} {'Imeas':>9} {'P':>8}"]
    for r in rows:
        out.append(f"{r['ch']:>2} {'ON' if r['on'] else 'off':>3} {r['vset']:>7.3f} "
                   f"{r['iset']:>6.3f} {r['v']:>9.4f} {r['i']:>9.5f} {r['p']:>7.3f}W")
    return "\n".join(out)


def log(duration, interval, path=None, channels=CHANNELS):
    path = Path(path or f"n6705_log_{time.strftime('%Y%m%d_%H%M%S')}.csv")
    t0 = time.time()
    s = connect()
    with path.open("w") as fh:
        cols = ["t_s"]
        for n in channels:
            cols += [f"ch{n}_V", f"ch{n}_I", f"ch{n}_P"]
        fh.write(",".join(cols) + "\n")
        try:
            while (elapsed := time.time() - t0) < duration:
                row = [f"{elapsed:.3f}"]
                for n in channels:
                    v = float(ask(s, f"MEAS:VOLT? (@{n})", timeout=20))
                    i = float(ask(s, f"MEAS:CURR? (@{n})", timeout=20))
                    row += [f"{v:.6f}", f"{i:.6f}", f"{v * i:.6f}"]
                fh.write(",".join(row) + "\n")
                fh.flush()
                time.sleep(max(0.0, interval - (time.time() - t0 - elapsed)))
        except KeyboardInterrupt:
            pass
        finally:
            s.close()
    return path


def set_channel(n, volts, amps):
    s = connect()
    try:
        write(s, f"VOLT {volts},(@{n})")
        write(s, f"CURR {amps},(@{n})")
        time.sleep(0.1)
        return ask(s, "SYST:ERR?")
    finally:
        s.close()


def output(n, on):
    s = connect()
    try:
        write(s, f"OUTP {'ON' if on else 'OFF'},(@{n})")
        time.sleep(0.2)
        return ask(s, "SYST:ERR?")
    finally:
        s.close()


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "status"
    if cmd == "status":
        print(ident())
        print(fmt(status()))
    elif cmd == "log":
        dur = float(argv[2]) if len(argv) > 2 else 10.0
        iv = float(argv[3]) if len(argv) > 3 else 0.5
        p = log(dur, iv, argv[4] if len(argv) > 4 else None)
        print(f"wrote {p}")
    elif cmd == "set":
        print(set_channel(int(argv[2]), float(argv[3]), float(argv[4])))
    elif cmd in ("on", "off"):
        print(output(int(argv[2]), cmd == "on"))
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
