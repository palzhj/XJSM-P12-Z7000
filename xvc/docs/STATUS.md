# Project Status — XJSM-P12-Z7000 XVC

> Last updated: 2026-11-03 08:10
> Current version: **v12** (image `835b4152` / `d8685f59`, bitstream `7272de42`)
> **2026-11-04 on-board test: 11/11 all passed** ✅


---

## 1. One-Line Status

**The 12-channel + 1 broadcast engine XVC over Ethernet system is complete**: 29/29 functional tests passed,
timing closed (WNS +0.307 ns), zero lint violations in hand-written RTL, zero methodology violations.

---

## 2. Hardware

| Item | Value |
|---|---|
| Board | AX7Z020B + AC7Z020 |
| Device | XC7Z020-2CLG400I |
| Memory | 1 GB DDR3 |
| Boot | SD card (TXS02612RTWR level shifting) |
| Expansion ports | J20 / J21 (12 JTAG groups, 48 pin) |

## 3. Architecture

```
PC (Vivado) ──Ethernet──► Zynq PS ──AXI──► PL
                            │               ├─ jtag0..11  (0x43C00000+ch*0x10000)
                            │               ├─ jtag12     (0x43CC0000) broadcast engine
                            │               ├─ bcast_regs (0x43CD0000) control registers
                            │               └─ repeater   (combinational arbitration)
                            └─ 13 TCP ports: 2542 + 2543..2554
```

## 4. Address Map

| Address | Contents | TAG |
|---|---|---|
| `0x43C00000 + ch*0x10000` | ch0..ch11 channel engines | `0xA7000000` |
| `0x43CC0000` | Broadcast engine | `0xA7000000` |
| `0x43CD0000` | Broadcast control register block | `0xB7000000` |

### Broadcast Control Registers

| Offset | Name | Description |
|---|---|---|
| `0x00` | CTRL | bit0 = `bcast_en` |
| `0x04` | BCMASK | [11:0] channels participating in broadcast (default 0xFFF) |
| `0x08` | CHSEL | [3:0] TDO source |
| `0x0C` | TAG | `0xB7000000` |
| `0x10` | STATUS | effective mask |

## 5. Versions and Artifacts

| Artifact | md5 | Description |
|---|---|---|
| **BOOT.BIN** | `835b4152` | 5,177,792 B, FSBL 98,312 |
| **image.ub** | `d8685f59` | 17,870,984 B |
| Bitstream | `7272de42` | 5,137,208 B (12 channels + 1 broadcast engine + I2C EMIO) |
| Server | `d6728f30` | session management + self-healing + **TCP big-endian length fix** |
| xvcinfo | `55a4b777` | register block read/write |
| oled_ip | `1c6600c4` | OLED display (6×24 IP + 12 ports + Broadcast) |
| UI | 23,641 B | TX used + BC badge |

## 6. Quality Metrics

| Dimension | Value | Status |
|---|---|---|
| **Functional tests** | **73/73** (v12 `fulltest_v12.py`) | ✅ |
| **TCP shift** | 21 bit widths + 6 data patterns, all passed | ✅ |
| **Timing WNS** | +0.307 ns | ✅ |
| **Failing endpoints** | 0 | ✅ |
| **Methodology violations** | 0 | ✅ |
| **RTL lint** (hand-written) | 0 | ✅ |
| **LUT** | 9,057 / 53,200 (17.02%) | ✅ |
| **FF** | 7,589 / 106,400 (7.13%) | ✅ |
| **IO** | 48 / 125 (38.4%) | ✅ |
| **BRAM / DSP** | 0 / 0 | ✅ |

## 7. Performance

| Operation | Result |
|---|---|
| FPGA programming | 10.27 s / 91.5 Mbit (20/20 runs, ±0.36%) |
| Flash programming | 200.7 s (including verification) |
| TCK | 10 MHz (DIV=5) |
| 12-channel parallel | 6.2× speedup |
| **Broadcast** | single engine, does not scale linearly with channel count |

## 8. Items Completed This Round (2026-11-02 ~ 11-03)

| # | Item | Result |
|---|---|---|
| 1 | Root cause located: missing `apply_ps7_config` | FSBL 65,544 → **98,312** (= vendor) ✅ |
| 2 | Image failed to boot | Fixed ✅ |
| 3 | Account credentials | `iheper` / `root`, password set per unit ✅ |
| 4 | Web console | silent operation + BC badge + TX used ✅ |
| 5 | **13th broadcast engine** | clean three-stage architecture ✅ |
| 6 | **0x40 register would not write** | switched to a separate register block + `==` decoding ✅ |
| 7 | **Broadcast 12× slower** | single-engine broadcast, hardware parallel ✅ |
| 8 | Single port single session | pid file + process verification ✅ |
| 9 | Broadcast exclusivity (REFUSE) | 12/12 refused + recovery ✅ |
| 10 | Broadcast crash self-healing | checked on accept ✅ |
| 11 | S_BC state machine | bit-boundary switching ✅ |
| 12 | **48 × TIMING-18** | I/O delay + multicycle → **0** ✅ |
| 13 | AMD ROSS MCP | installed + fixed 3 bugs ✅ |
| 14 | **PetaLinux downloads over the network on every build** | `BB_NO_NETWORK=1` + local mirror → fully offline ✅ |

## 9. Known Limitations

| Item | Description |
|---|---|
| ~~Image on the card~~ | ✅ **written with v12 and verified** (`835b4152` / `d8685f59`) |
| ~~Board bitstream~~ | ✅ **loaded from the card** (`7272de42`, TAG `0xA7000000` / broadcast `0xB7000000` confirmed on hardware) |
| External JTAG chain | not connected, on-board programming not verified |
| Broadcast cleanup | `bcast_en` remains set when the process is SIGKILLed, recovered by self-healing/restart |

## 10. Document Index

| File | Contents |
|---|---|
| `STATUS.md` | **this file** — overall status |
| `BLOCK_DIAGRAM.md` | system/RTL block diagrams + state machines + session management |
| `BUILD_DEPLOY_GUIDE.md` | complete build and deployment guide |
| `REVIEW.md` | AMD ROSS MCP review report |
| `rtl_lint_report.md` | RTL lint report |
| `METHODOLOGY_RESOLUTION_REPORT.md` | timing methodology report |
| `ROOTCAUSE_FIXED.md` | root-cause analysis of the boot failure |
| `port_fsm.svg` | port state machine diagram |
| `system_block.svg` / `rtl_block.svg` | block diagrams |
| `PETALINUX_LOCAL_BUILD.md` | **local source package build manual** (473 lines) |
| `OFFLINE_BUILD.md` | concise offline build guide |
| `DEVELOPMENT_AND_DEBUG.md` | development and debugging manual |
| `WEB_CONSOLE.md` | web console instructions |
| `JTAG12_J20_J21.md` | pin mapping |
| `KNOWN_ISSUES.md` | known issues |

| **`MANUFACTURING.md`** | **production programming work instruction** (705 lines, 17 factory inspection items) |
| `XVC_G1_STATUS.md` | 12 + broadcast engine status details (533 lines) |
| `CHANNELS12.md` | 12-channel description |
| `BOOT_WORKFLOW_1027S.md` | boot workflow and the 1027-second programming record |
| `JTAG_RECOVERY.md` / `SD_RESCUE_JTAG.md` | JTAG / SD rescue |
| `XSA_EXPORT_REVIEW.md` | XSA export review |
| `WHY_FSBL_DIFFERS.md` | FSBL difference analysis |
| `BUILD_2023_1_FINDINGS.md` | 2023.1 build findings |
| `U20_U22_BUILD.md` / `U22_BUILD.md` | VM build records |
| `FLASH_PROGRAMMING_FINDINGS.md` | flash programming investigation |
| `OLED_TEST_STEPS.md` | OLED verification steps (historical) |
| `README.md` | documentation master index |

