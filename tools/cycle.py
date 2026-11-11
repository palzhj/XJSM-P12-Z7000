#!/usr/bin/env python3
"""Power-cycle one N6705C channel and capture the transient.

    python3 tools/cycle.py 3 --dwell 2 --settle 8 --out tools/cycle_ch3.csv

Channel-list commands need a COMMA before the list (`OUTP OFF,(@3)`); the
space-separated form is rejected with -103 "Invalid separator" and silently
does nothing. Every state change here is therefore read back and verified.
"""
import argparse
import statistics
import time

import n6705


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("channel", type=int)
    ap.add_argument("--dwell", type=float, default=2.0, help="seconds held off")
    ap.add_argument("--settle", type=float, default=8.0, help="seconds logged after ON")
    ap.add_argument("--pre", type=float, default=1.0, help="seconds logged before OFF")
    ap.add_argument("--out", default=None)
    ap.add_argument("--volts", type=float, default=None, help="setpoint applied while off")
    ap.add_argument("--amps", type=float, default=None, help="limit applied while off")
    a = ap.parse_args()

    ch = a.channel
    out = a.out or f"tools/cycle_ch{ch}.csv"
    s = n6705.connect()
    cur_limit = float(n6705.ask(s, f"CURR? (@{ch})"))   # for the CC-risk check

    phase = {"name": "pre"}
    rows = []          # (t, phase, volts, amps)

    n = {"i": 0}

    def sample():
        # Current every sample (it is what catches inrush); voltage every 4th so
        # the loop still runs ~25-30 Hz instead of ~18 Hz.
        i = float(n6705.ask(s, f"MEAS:CURR? (@{ch})", timeout=20))
        n["i"] += 1
        v = float(n6705.ask(s, f"MEAS:VOLT? (@{ch})", timeout=20)) if n["i"] % 4 == 1 else float("nan")
        rows.append((time.time(), phase["name"], v, i))
        return v, i

    def state():
        return n6705.ask(s, f"OUTP? (@{ch})").strip()

    t0 = time.time()
    while time.time() - t0 < a.pre:
        sample()

    n6705.write(s, f"OUTP OFF,(@{ch})")
    time.sleep(0.15)
    if state() != "0":
        raise SystemExit(f"FAILED: output did not turn off (OUTP? = {state()}, "
                         f"err {n6705.ask(s, 'SYST:ERR?')})")

    phase["name"] = "off"
    t_off = time.time()
    while time.time() - t_off < a.dwell:
        sample()

    if a.volts is not None:
        n6705.write(s, f"VOLT {a.volts},(@{ch})")
    if a.amps is not None:
        n6705.write(s, f"CURR {a.amps},(@{ch})")

    n6705.write(s, f"OUTP ON,(@{ch})")
    t_on = time.time()
    if state() != "1":
        raise SystemExit(f"FAILED: output did not turn on (err {n6705.ask(s, 'SYST:ERR?')})")

    phase["name"] = "on"
    while time.time() - t_on < a.settle:
        sample()

    err = n6705.ask(s, "SYST:ERR?")
    s.close()

    pre = [r for r in rows if r[1] == "pre"]
    off = [r for r in rows if r[1] == "off"]
    on = [r for r in rows if r[1] == "on"]

    def vols(rs):
        xs = [r[2] for r in rs if r[2] == r[2]]      # drop NaN samples
        return statistics.median(xs) if xs else float("nan")

    pre_i = statistics.median([r[3] for r in pre])
    off_i = statistics.median([r[3] for r in off])
    peak = max(on, key=lambda r: r[3])
    tail = [r[3] for r in on if r[0] > t_on + 0.4 * a.settle]
    settled = statistics.median(tail) if tail else float("nan")
    # first sample after ON that is within 10 % of the settled value
    t_reach = next((r[0] - t_on for r in on
                    if abs(r[3] - settled) < 0.1 * abs(settled)), float("nan"))
    on_v = [r[2] for r in on if r[2] == r[2]]
    v_min = min(on_v) if on_v else float("nan")

    with open(out, "w") as fh:
        fh.write("t_rel_s,phase,volts,current_A\n")
        for t, ph, v, i in rows:
            fh.write(f"{t - t_on:.4f},{ph},{'' if v != v else f'{v:.6f}'},{i:.6f}\n")

    print(f"channel            : {ch}")
    print(f"pre-cycle          : {pre_i:.5f} A  ({vols(pre):.4f} V)")
    print(f"off (verified)     : {off_i:.6f} A  ({vols(off):.4f} V)")
    print(f"on-peak            : {peak[3]:.5f} A  at t+{peak[0] - t_on:.3f} s")
    print(f"on min V           : {v_min:.4f} V")
    print(f"settled            : {settled:.5f} A")
    print(f"reaches 90% at     : t+{t_reach:.3f} s")
    print(f"inrush over steady : {peak[3] - settled:+.5f} A "
          f"({(peak[3] / settled if settled else float('nan')):.2f}x)")
    limit = a.amps if a.amps is not None else cur_limit
    print(f"current limit      : {limit:.3f} A")
    print(f"headroom at peak   : {limit - peak[3]:+.3f} A"
          + ("   ⚠ PEAK WITHIN 5% OF LIMIT" if peak[3] > 0.95 * limit else ""))
    print(f"samples            : {len(rows)} ({len(rows) / (a.pre + a.dwell + a.settle):.1f}/s)")
    print(f"errors             : {err}")
    print(f"csv                : {out}")


if __name__ == "__main__":
    main()
