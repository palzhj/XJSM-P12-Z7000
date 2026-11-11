# XVC Test Suite

## Quick start

```bash
# Set the board password first (never hard-coded)
export XVC_PASSWORD='<your-password>'

# Full test (73 items) — network + serial
python3 fulltest_v12.py

# Network only (quick production-line check, for use without a serial port)
python3 fulltest_v12.py --net-only
```

**Exit code 0 = all passed** ✓ can be used directly for production-line automation ✓

## Prerequisites

| Item | Requirement |
|---|---|
| Board | Booted, `192.168.1.113` reachable |
| Serial | `/dev/ttyUSB3` @115200 (`--net-only` skips it) |
| Login | `root` + password from `XVC_PASSWORD` env var (needed by the serial items) |
| Python | 3.8+ (standard library only) |

## Coverage (73 items)

| Group | Content | Items |
|---|---|---|
| A | Network and Web console | 6 |
| B | 13 XVC ports | 5 |
| C | Protocol edge cases (settck / shift 21 bit widths / TDI 6 modes / invalid input) | 34 |
| D | engine registers (12 channels + broadcast) | 6 |
| E | Broadcast register block | 5 |
| F | Concurrency and exclusivity | 2 |
| G | Broadcast lifecycle | 5 |
| H | Robustness (fast reconnect / mid-transfer disconnect / 524288 bit) | 4 |
| I | OLED | 2 |

## Files

| File | Notes |
|---|---|
| `fulltest_v12.py` | **Current version**, 73 items |
| `fulltest.py` | Early 29-item version (writes registers directly with `devmem`, does not test TCP shift) |

> ⚠️ The shift items in `fulltest.py` only verify register writes; they **do not go through the TCP protocol** ✗
> So the early "29/29 pass" masked a byte-order bug in TCP shift ✗ Please rely on `fulltest_v12.py`

## Known test pitfalls

| Pitfall | Notes |
|---|---|
| `settck:` | Must send the period as **4 binary bytes** (network order); ASCII is interpreted as a length error |
| Shift within a broadcast | Must **reuse the same TCP connection**; a new connection is rejected |
| Fast reconnect | The server waits up to 1.5 s for the previous session to exit; test intervals < 120 ms may occasionally be rejected |
