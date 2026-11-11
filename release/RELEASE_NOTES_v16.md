# v16 — Broadcast + 12-Engine XVC Remote JTAG (K7 programming verified)

**Release date**: 2026-11-06

This release turns an AC7Z020 (XC7Z020) into a **13-port network JTAG debugger**,
configuring an external AMD Xilinx FPGA over Ethernet and replacing
a traditional USB JTAG cable. **A full K7 bitstream has been programmed
successfully over the network (91.5 Mbit / 15.9 s).**

---

## Downloads

| File | Size | MD5 |
|---|---|---|
| `BOOT.BIN` | 5,177,792 | `835b415252fe70d7b8522620578bda28` |
| `image.ub` | 17,870,984 | `d8685f5975a001ffd71e3eea0e7f11ee` |
| `system.bit` | 4,045,674 | `7272de4272ca910779471c30b0d86584` |
| `system.xsa` | 671,754 | `c5f8d2e9a5f471ed15ae3c19042f2fbc` |
| `xvc_v16.tar.gz` | 19 MB | `f27e52a4c50fbbf7023fa0b79100ef09` |

### ⚠️ GPL source obligation

`BOOT.BIN` and `image.ub` embed the **Linux kernel, busybox, glibc** and other
GPL / LGPL components. Distributing these binaries requires providing the
**complete corresponding source** as well.

How to obtain the sources for this release:

1. **This project's sources** (RTL, server, web, docs):
   https://github.com/palzhj/XJSM-P12-Z7000/tree/v16

2. **PetaLinux / Yocto upstream sources** (kernel, busybox, rootfs contents):
   - Build configuration: `xvc/petalinux/xvc/project-spec/`
   - Run `petalinux-build` as described in
     [`xvc/docs/BUILD_DEPLOY_GUIDE.md`](https://github.com/palzhj/XJSM-P12-Z7000/blob/main/xvc/docs/BUILD_DEPLOY_GUIDE.md)
     to rebuild everything
   - Upstream component versions and `SRC_URI` are in `build/conf/` and the
     individual `*.bb` recipes
   - Kernel source: Xilinx `linux-xlnx` (GPL-2.0), v2023.1 branch

3. For a **byte-for-byte reproducible** source bundle, request one in writing
   under GPL-2.0 §3: open an issue on this repository and state version `v16`.

---

## Quick Start

### 1. Flash the SD card (FAT32)

Copy `BOOT.BIN` + `image.ub` to the card root, insert, and power up.
(This carrier board has **no QSPI flash**; it can only boot from SD.)

### 2. Log in

```
root / <password>
```

### 3. Connect from Vivado

```
Open Hardware Manager → Open Target → Open New Target
  → Add Xilinx Virtual Cable (XVC)
  → Host: <board IP>    Port: 2543       ← ch0 = "G1"
```

> **Do not use 2542** — that is the broadcast-only port and carries no signal
> unless the mask is non-empty.

### 4. Program a bitstream

```tcl
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target -xvc_url 192.168.1.113:2543
set dev [lindex [get_hw_devices xc7k325t*] 0]
set_property PROGRAM.FILE {top.bit} $dev
program_hw_devices $dev
```

---

## Five Critical Bugs Fixed in This Release

### 🔴 1. `stream_zero` never writes the LEN register

For shifts of ≥8192 bits with TMS all zero, the code took the FIFO streaming
path — but that function **never wrote `0x00` (LEN)**, so the RTL did not know how
many bits to shift. **Every long shift transferred corrupted data.**

**Symptom**: Vivado completed 2666 shifts with zero errors, yet reported
`[Labtools 27-3165] End of startup status: LOW` (DONE never went high).

**Evidence** (BYPASS loopback):

| Shift length | Path | Data match |
|---|---|---|
| 4,096 bit | 32-bit chunks | **100.0%** |
| 65,536 bit | streaming ✗ | **50.3%** ✗ |
| 262,144 bit | streaming ✗ | 50% ✗ |

**Fix**: streaming path disabled; always use the 32-bit chunked path
(measured 5.8 Mbit/s — good enough).

### 2. Vivado sends little-endian, the XVC spec says big-endian

The 4-byte `settck:` period was parsed as big-endian → 100 ns became 160 million ns
→ DIV clamped to 65535 → **TCK 0.001 MHz** → Vivado timed out with
`[Labtools 27-3104] Unable to open port`.

**Fix**: byte order is **auto-detected and locked per connection**.
`settck` periods are small and unambiguous, so they lock the order; while
unlocked, `shift` defaults to big-endian (per spec).

### 3. `settck` computed a DIV but never wrote it to hardware

The single-channel path wrote `0x14` only once at startup and never again
→ the clock stayed at 10 MHz, so a client requesting 1 MHz had no effect.

**Fix**: `wr(0x14, tck_div)` before every shift. The `-d` argument changed
meaning from "force" to "**fastest allowed**".

### 4. Stale process kept running; the new one exited silently

`bind()` failure just did `return 1`, while the old binary kept serving
→ **code changes appeared to have no effect** (took three rounds to diagnose).

**Fix**: actionable message on `bind` failure + version banner at startup.

### 5. Self-heal logic conflicted with the mask semantics

`heal_bcast_if_stale()` treated `bcast_en` as "is a broadcast session alive",
but it now means "is the UI mask non-empty" → every accept wiped the UI setting
→ symptom: "when I uncheck all BC boxes, one port always stays selected".

**Fix**: the server **never rewrites** `bcast_en`; it is owned entirely by the
web UI.

---

## Verification

### K7 programming (decisive)

```
INFO: [Labtools 27-3164] End of startup status: HIGH
program_hw_devices: elapsed = 00:00:16
=== Programming succeeded in 15.9 s ===
```

### BYPASS loopback (data integrity)

| Bits | Match | Time |
|---|---|---|
| 65,536 | **100.00%** | 0.02 s |
| 262,144 | **100.00%** | 0.06 s |
| 1,048,576 | **100.00%** | 0.24 s |

### Regression tests

```
python3 xvc/tests/fulltest_v12.py   →  76/76 all passed ✅
```

### Resources and timing

| Metric | Value |
|---|---|
| LUT | 9,057 (17.02%) |
| FF | 7,589 (7.13%) |
| WNS / WHS | +0.307 ns / +0.048 ns |
| Failing endpoints | 0 |

---

## Known Limitations

| Item | Notes |
|---|---|
| No QSPI | The whole system lives on the SD card |
| ramdisk root filesystem | Not persistent; store the serial number in `SN.TXT` on the SD card |
| busybox has no `pkill` | Use `kill -9 $(ps\|grep\|awk)` |
| Broadcast mask is a static reservation | Channels stay reserved after the session ends; clear the mask in the UI |
| OLED relies on internal weak pull-ups | Add external 4.7 kΩ pull-ups |

See the full list of 34 pitfalls in
[`xvc/docs/KNOWN_ISSUES.md`](https://github.com/palzhj/XJSM-P12-Z7000/blob/main/xvc/docs/KNOWN_ISSUES.md).

---

## Rebuilding from Source

```bash
# 1) bitstream
vivado -mode batch -source xvc/vivado/build_jtag12p.tcl

# 2) PetaLinux image (needs 2023.1 + local source packages)
cd xvc/petalinux/xvc
petalinux-build
petalinux-package --boot --fsbl zynq_fsbl.elf --fpga system.bit --u-boot u-boot.elf --force
```

Details in
[`xvc/docs/BUILD_DEPLOY_GUIDE.md`](https://github.com/palzhj/XJSM-P12-Z7000/blob/main/xvc/docs/BUILD_DEPLOY_GUIDE.md).

---

## License

Project-owned code: **MIT** (see [LICENSE](https://github.com/palzhj/XJSM-P12-Z7000/blob/main/LICENSE)).
Third-party content and generated artifacts are described in
[NOTICE](https://github.com/palzhj/XJSM-P12-Z7000/blob/main/NOTICE).
