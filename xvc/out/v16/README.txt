========================================================
XJSM-P12-Z7000  v16 release package
2026-11-06
========================================================

## 🔴 Fixed in this release: Labtools 27-3104 Unable to open port

### Root cause (three overlapping issues)

  1. Vivado's XVC client sends **little-endian**, but the XVC 1.0 spec says **big-endian** ✗
     The server parsed as big-endian → the settck period became astronomically large
     → DIV clamped to 65535 → TCK 0.001 MHz → Vivado timed out → 27-3104

  2. The DIV computed by settck was never written to hardware (the single-channel path wrote it only once at startup)

  3. If the old process was not killed cleanly, the new process failed to bind and "exited silently",
     while the old binary kept serving — which looks like "changed the code, behaviour unchanged"

### Fixes

  - Byte order: **auto-detected and locked per connection**
      · settck periods are small and rarely ambiguous → use it to lock (take the smaller of the two interpretations)
      · Before locking, shift defaults to big-endian (the spec)
      · All subsequent 4-byte fields on the same connection follow the locked order
  - Write wr(0x14, tck_div) before every shift
  - settck echoes back the actual period (in the same byte order as the client)
  - Single-instance protection: a bind failure prints an actionable hint
  - Startup banner carries the version number so you can confirm which build is running

### Measured (24 items each for BE / LE, all passed)

  Big-endian (spec / most tools)            ✅ 24/24
  Little-endian (Vivado)                    ✅ 24/24
  Big-endian + no settck (fallback)         ✅ 24/24

  Regression test fulltest_v12.py           ✅ 76/76

## How to connect from Vivado

  ✅ Use port 2543 (ch0 = "G1"), 2544..2554 = ch1..ch11
  ❌ Do not use 2542 (broadcast-only port, needs a mask to produce signals)

## Upgrade steps (the old process must be fully cleared)

  for p in $(pidof xvcserver_g1); do kill -9 $p; done
  sleep 2
  pidof xvcserver_g1 || echo CLEAN       # must be empty
  /usr/bin/xvcserver_g1 -a 0x43C00000 -d 5 > /tmp/srv.log 2>&1 &
  head -3 /tmp/srv.log                   # you should see the version banner

## How to confirm the log is normal

  $ head -4 /tmp/srv.log
  ch0 PL_TAG=0xA7000000 (expect 0xA7xxxxxx)
  ch0 FIFO_STATUS=0x00000080  tx_free=128 rx_used=0
  xvcserver_g1 v20 ... byte order auto-detect      ← version banner
  xvcserver_g1: JTAG@0x43C00000, TCP 2543(+2542) ...

  $ grep settck /tmp/srv.log | tail -5
  settck: request 1000 ns (LE) -> DIV 50 (TCK 1.000 MHz)   ← (LE) means detected as little-endian ✓

## Symptom → cause

  | Symptom                            | Cause |
  |------------------------------------|-------|
  | Labtools 27-3104                   | ① using port 2542 ② settck byte order → TCK 0.001MHz ③ old process holding the port |
  | K7/A7 visible briefly then lost    | settck did not take effect / DIV not written to hardware |
  | Changed code, behaviour unchanged  | old process still running (bind failed, silent exit) |

## Key checksums

  BOOT.BIN       835b415252fe70d7b8522620578bda28
  image.ub       d8685f5975a001ffd71e3eea0e7f11ee
  system.bit     7272de4272ca910779471c30b0d86584
  xvcserver_g1   20a5470807262288076eccd0c2b58771
  xvcinfo        b3b9d7dcee26047463cd079c3a573903
  index.html     1a84ad19f14ee8c6fda21e7260e7a051
  oled_ip        bcd00f93ff113b719f34921f2534bfa7
