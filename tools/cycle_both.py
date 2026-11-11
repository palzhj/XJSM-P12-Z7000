#!/usr/bin/env python3
"""Power-cycle CH4 and CH3 in the safe order and log both rails.

    python3 tools/cycle_both.py --out tools/cycle_both.csv

Order is deliberate: CH4 (K7) off -> CH3 (Zynq) off -> CH3 on -> CH4 on.
Bringing the Zynq back before the K7 means the Zynq is never sitting dead while
the K7 is driving I/O into it (the 1.4 V back-drive measured on this bench).
"""
import argparse
import statistics
import time

import n6705

CH_ZYNQ, CH_K7 = 3, 4


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dwell", type=float, default=2.0)
    ap.add_argument("--boot", type=float, default=5.0, help="seconds Zynq boots before K7 on")
    ap.add_argument("--settle", type=float, default=12.0)
    ap.add_argument("--out", default="tools/cycle_both.csv")
    a = ap.parse_args()

    s = n6705.connect()
    rows = []
    phase = {"name": "pre"}

    def sample():
        i3 = float(n6705.ask(s, f"MEAS:CURR? (@{CH_ZYNQ})", timeout=20))
        i4 = float(n6705.ask(s, f"MEAS:CURR? (@{CH_K7})", timeout=20))
        v3 = float(n6705.ask(s, f"MEAS:VOLT? (@{CH_ZYNQ})", timeout=20))
        v4 = float(n6705.ask(s, f"MEAS:VOLT? (@{CH_K7})", timeout=20))
        rows.append((time.time(), phase["name"], v3, i3, v4, i4))

    def run(seconds, name):
        phase["name"] = name
        t = time.time()
        while time.time() - t < seconds:
            sample()

    def switch(ch, on):
        n6705.write(s, f"OUTP {'ON' if on else 'OFF'},(@{ch})")
        time.sleep(0.2)
        want = "1" if on else "0"
        got = n6705.ask(s, f"OUTP? (@{ch})").strip()
        if got != want:
            raise SystemExit(f"FAILED ch{ch} -> {want}: OUTP?={got} "
                             f"err={n6705.ask(s, 'SYST:ERR?')}")

    run(2.0, "pre")

    switch(CH_K7, False)
    run(a.dwell, "off4")
    switch(CH_ZYNQ, False)
    run(a.dwell, "off3")
    t_on3 = time.time()
    switch(CH_ZYNQ, True)
    run(a.boot, "boot3")
    t_on4 = time.time()
    switch(CH_K7, True)
    run(a.settle, "on4")

    err = n6705.ask(s, "SYST:ERR?")
    s.close()

    with open(a.out, "w") as fh:
        fh.write("t_rel_s,phase,ch3_V,ch3_I,ch4_V,ch4_I\n")
        for t, ph, v3, i3, v4, i4 in rows:
            fh.write(f"{t - t_on3:.4f},{ph},{v3:.6f},{i3:.6f},{v4:.6f},{i4:.6f}\n")

    def med(rs, idx):
        return statistics.median([r[idx] for r in rs]) if rs else float("nan")

    print(f"errors: {err}")
    print(f"\n{'phase':>6} {'CH3 V':>8} {'CH3 I':>8} {'CH4 V':>8} {'CH4 I':>8}")
    for ph in ("pre", "off4", "off3", "boot3", "on4"):
        rs = [r for r in rows if r[1] == ph]
        if rs:
            print(f"{ph:>6} {med(rs,2):>8.4f} {med(rs,3):>8.4f} {med(rs,4):>8.4f} {med(rs,5):>8.4f}")

    last = rows[-6:]
    print(f"\nfinal CH3: {med(last,3):.4f} A @ {med(last,2):.4f} V = "
          f"{med(last,2)*med(last,3):.3f} W")
    print(f"final CH4: {med(last,5):.4f} A @ {med(last,4):.4f} V = "
          f"{med(last,4)*med(last,5):.3f} W")
    print(f"csv: {a.out}")


if __name__ == "__main__":
    main()
