# XJSM-P12-Z7000 — Broadcast + 12-Engine XVC Remote JTAG

A **broadcast + 12-channel XVC (Xilinx Virtual Cable) server** implemented on a
**AMD Xilinx Zynq-7020 (AC7Z020)**, providing network-based remote JTAG access to
an external **AMD Xilinx FPGA** scan chain — replacing a traditional USB JTAG
cable. Includes a 0.96" OLED status display and a web console.

> In one sentence: turn a small Zynq board into a 13-port network JTAG debugger.

---

## System Overview

```
                   ┌──────────────────────────────────────────┐
                   │  AC7Z020 (XC7Z020)                        │
  PC / Vivado ────►│  ┌────────────┐   ┌───────────────────┐   │
   TCP 2542/2543   │  │ PS: Linux  │──►│ PL: 13× jtag_ctrl │───┼──► J20 G1/G2
   ... 2554        │  │  xvcserver │   │  + broadcast eng. │   │     │
                   │  └────────────┘   │  + I2C EMIO       │   │     ▼
                   │        │          └───────────────────┘   │  ┌──────────┐
                   │        └── OLED (SSD1315, I2C1) ──────────┼─►│ AMD      │
                   │                                          │  │ Xilinx   │
                   │                                          │  │ FPGA     │
                   │                                          │  └──────────┘
                   └──────────────────────────────────────────┘
```

| Component | Description |
|---|---|
| **13 JTAG engines** | `jtag0..11` @ `0x43C00000 + ch*0x10000` (12 independent channels) + `jtag12` @ `0x43CC0000` (broadcast-only engine) |
| **Broadcast register block** | `0x43CD0000`: `CTRL / BCMASK / CHSEL / TAG` |
| **XVC server** | TCP `2542` (broadcast) + `2543..2554` (ch0..ch11), one session per channel |
| **Web console** | `http://<board>/` — port status, mask, TCK, reset |
| **OLED** | 128×64, shows 12 port states / broadcast mask / IP / TCK |

---

## Port Assignment

| Port | Purpose | Notes |
|---|---|---|
| `2542` | **Broadcast** | Requires a non-empty BCMASK to carry any signal |
| `2543` | ch0 = **G1** | ← **this is what Vivado normally uses** |
| `2544..2554` | ch1..ch11 | |
| `80` | Web console | |

---

## Quick Start

### 1. Flash the SD card

Copy the two files from `release/v16/` (or `xvc/out/v16/sd_card/`) to the **FAT32**
root of an SD card:

```
BOOT.BIN      5,177,792 B   md5 835b415252fe70d7b8522620578bda28
image.ub     17,870,984 B   md5 d8685f5975a001ffd71e3eea0e7f11ee
```

Insert the card and power up. (This carrier board has **no QSPI flash**; it can
only boot from SD.)

### 2. Log in

```
root / <password set when the image was built>
```

No password ships in this repository. The image is built with placeholder
hashes, so set your own before building — see
[`xvc/docs/MANUFACTURING.md`](xvc/docs/MANUFACTURING.md) §8.4.

### 3. Connect from Vivado

```
Open Hardware Manager → Open Target → Open New Target
  → Add Xilinx Virtual Cable (XVC)
  → Host: <board IP>    Port: 2543
```

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

## Repository Layout

```
xvc/
├── vivado/                     FPGA side
│   ├── rtl/                    Verilog sources (jtag_ctrl / jtag_bcast_regs / i2c_*)
│   ├── constraints/            XDC
│   ├── build_jtag12p.tcl       one-shot build script
│   └── out_jtag12p/            system_wrapper.bit + system.xsa
├── petalinux/
│   ├── apps/                   server / xvcinfo / oled_ip / i2cprobe sources
│   └── xvc/project-spec/       meta-user recipes (the only config that must persist)
├── web/                        Web console (index.html + CGI)
├── tests/                      fulltest_v12.py (76 checks)
├── tools/                      debug scripts (TCL / Python)
├── sim/                        RTL simulation (cocotb style)
├── docs/                       27 design / build / manufacturing documents
└── out/v16/                    ready-to-use release artifacts
sw/oled/                        OLED application (for cross-compiling on the host)
test_bits/                      test bitstreams
```

---

## Key Documents

| Document | Contents |
|---|---|
| [`xvc/docs/MANUFACTURING.md`](xvc/docs/MANUFACTURING.md) | **Factory programming work instruction** (~800 lines, 18 end-of-line checks) |
| [`xvc/docs/STATUS.md`](xvc/docs/STATUS.md) | Overall project status, versions, checksums |
| [`xvc/docs/BLOCK_DIAGRAM.md`](xvc/docs/BLOCK_DIAGRAM.md) | System / RTL block diagram, state machine |
| [`xvc/docs/BUILD_DEPLOY_GUIDE.md`](xvc/docs/BUILD_DEPLOY_GUIDE.md) | Complete build & deployment guide |
| [`xvc/docs/KNOWN_ISSUES.md`](xvc/docs/KNOWN_ISSUES.md) | **34 pitfalls hit** (with root cause and fix) |
| [`xvc/docs/PETALINUX_LOCAL_BUILD.md`](xvc/docs/PETALINUX_LOCAL_BUILD.md) | Offline PetaLinux build |
| [`xvc/tests/README.md`](xvc/tests/README.md) | Test suite description |
| [`NOTICE`](NOTICE) | Third-party content and licensing notes |

---

## Register Map (per engine)

| Offset | Name | Description |
|---|---|---|
| `0x00` | LEN | Number of bits to shift |
| `0x04` | TMS | 32-bit TMS data |
| `0x08` | TDI | 32-bit TDI data |
| `0x0C` | TDO | Read-back |
| `0x10` | CTRL | bit0 start (self-clearing) / bit2 FIFO flush |
| `0x14` | DIV | TCK divider = `100 MHz / (2*DIV)`; reads back PL_TAG `0xA7000000` |
| `0x18` | DIV_RB | Divider read-back |
| `0x1C` | TXD | FIFO write |
| `0x20` | RXD | FIFO read |
| `0x24` | STATUS | `[7:0]` tx_free / `[15:8]` rx_used |
| `0x28` | DONE | Completed-shift counter |
| `0x2C` | PH | Phase counter (debug) |
| `0x30` | STATE | `[9:8]` state / `[7:2]` bits / bit1 streaming / bit0 busy |
| `0x34` | START | |
| `0x38` | SEQ | Upper 16 bits = go_seq |
| `0x3C` | CHSEL | |
| `0x40` | BCMASK | |

Broadcast register block `0x43CD0000`:

| Offset | Name | Description |
|---|---|---|
| `0x00` | CTRL | bit0 `bcast_en` |
| `0x04` | BCMASK | 12-bit mask (0 = take over no channel) |
| `0x08` | CHSEL | TDO source |
| `0x0C` | TAG | `0xB7000000` |

---

## Resources and Performance

| Metric | Value |
|---|---|
| LUT | 9,057 (17.02%) |
| FF | 7,589 (7.13%) |
| IOB | 48 / 125 |
| WNS / WHS | +0.307 ns / +0.048 ns |
| Failing endpoints | 0 |
| Shift throughput | 5.6–9.0 Mbit/s (TCK 10 MHz) |
| Per-shift latency | 0.21–0.26 ms (6 bit) |
| Full bitstream (measured on a Kintex-7 325T) | 91.5 Mbit / **15.9 s** |

---

## Known Limitations

| Item | Notes |
|---|---|
| No QSPI | This carrier board has no configuration flash; the system lives entirely on SD |
| ramdisk root filesystem | Not persistent across power cycles; store the serial number in `SN.TXT` on the SD card |
| busybox has no `pkill` | Kill processes with `kill -9 $(ps\|grep\|awk)` |
| `-d` is an **upper bound** | `-d 5` = 10 MHz maximum; the client may request slower |
| Broadcast mask is a static reservation | Channels in the mask stay reserved after the session ends; clear the mask in the UI |

See [`KNOWN_ISSUES.md`](xvc/docs/KNOWN_ISSUES.md) for the full pitfall list.

---

## License

Project-owned code is released under the **MIT** license — see [`LICENSE`](LICENSE).
Third-party content and generated artifacts are described in [`NOTICE`](NOTICE).
Vendor documents (PG245, XAPP1251, UG908, UG470), Xilinx-generated
`ps7_init.*`, Vivado project files, and the bootable `BOOT.BIN` / `image.ub`
(which embed GPL components) are **not** distributed in this repository.
