# XJSM-P12-Z7000 XVC — Documentation Overview

> Last updated: 2026-11-03
> Version: **v12** (BOOT.BIN `835b4152` / image.ub `d8685f59`, 2026-11-04)

---

## Quick Start

| I want to… | See this |
|---|---|
| Understand the current project status | [STATUS.md](STATUS.md) |
| View the architecture diagrams | [BLOCK_DIAGRAM.md](BLOCK_DIAGRAM.md) + `system_block.svg` / `rtl_block.svg` |
| View the state machines | [port_fsm.svg](port_fsm.svg) |
| Build the image | [BUILD_DEPLOY_GUIDE.md](BUILD_DEPLOY_GUIDE.md) |
| **Build from a local source package (detailed manual)** | [PETALINUX_LOCAL_BUILD.md](PETALINUX_LOCAL_BUILD.md) |
| Offline / air-gapped build (concise version) | [OFFLINE_BUILD.md](OFFLINE_BUILD.md) |
| View quality reports | [REVIEW.md](REVIEW.md) / [rtl_lint_report.md](rtl_lint_report.md) / [METHODOLOGY_RESOLUTION_REPORT.md](METHODOLOGY_RESOLUTION_REPORT.md) |
| Troubleshoot boot problems | [ROOTCAUSE_FIXED.md](ROOTCAUSE_FIXED.md) |
| Connect external JTAG | [JTAG12_J20_J21.md](JTAG12_J20_J21.md) |
| Know the pitfalls | [KNOWN_ISSUES.md](KNOWN_ISSUES.md) |

---

## Documentation Categories

### Core (read these first)

| File | Lines | Contents |
|---|---|---|
| [STATUS.md](STATUS.md) | 132 | **Overall project status**: architecture, addresses, versions, quality metrics, limitations |
| [BLOCK_DIAGRAM.md](BLOCK_DIAGRAM.md) | 549 | System/RTL block diagrams, state machines, session management, timing constraints |
| [BUILD_DEPLOY_GUIDE.md](BUILD_DEPLOY_GUIDE.md) | ~1100 | Complete build and deployment guide (Vivado + PetaLinux) |
| [PETALINUX_LOCAL_BUILD.md](PETALINUX_LOCAL_BUILD.md) | 473 | **Local source package build manual** (12 chapters, including team sharing/troubleshooting) |
| [OFFLINE_BUILD.md](OFFLINE_BUILD.md) | 175 | Concise offline build instructions |
| [KNOWN_ISSUES.md](KNOWN_ISSUES.md) | 153 | 20 resolved + 7 pending |

### Diagrams

| File | Contents |
|---|---|
| `system_block.svg` | System block diagram (PC → PS → PL → target board) |
| `rtl_block.svg` | RTL block diagram (broadcast + 12 engines + mux + register table) |
| `port_fsm.svg` | Port state machine (four panels: TCP / RTL / shift / broadcast) |

### Quality Reports

| File | Contents |
|---|---|
| [REVIEW.md](REVIEW.md) | AMD ROSS MCP review (timing/resources/lint/methodology/function) |
| [rtl_lint_report.md](rtl_lint_report.md) | RTL lint: all 79 findings are in generated code, zero violations in hand-written RTL |
| [METHODOLOGY_RESOLUTION_REPORT.md](METHODOLOGY_RESOLUTION_REPORT.md) | Timing methodology: the fix process from 48 → 0 |

### Technical Analyses

| File | Contents |
|---|---|
| [ROOTCAUSE_FIXED.md](ROOTCAUSE_FIXED.md) | Root cause of the image failing to boot (missing `apply_ps7_config`) |
| [WHY_FSBL_DIFFERS.md](WHY_FSBL_DIFFERS.md) | Analysis of the differences between the self-built FSBL and the vendor one |
| [XSA_EXPORT_REVIEW.md](XSA_EXPORT_REVIEW.md) | Review of the Vivado XSA export contents |
| [BUILD_2023_1_FINDINGS.md](BUILD_2023_1_FINDINGS.md) | Issues found during the 2023.1 build process |

### Operating Manuals

| File | Contents |
|---|---|
| [DEVELOPMENT_AND_DEBUG.md](DEVELOPMENT_AND_DEBUG.md) | Development and debugging manual |
| [WEB_CONSOLE.md](WEB_CONSOLE.md) | Web console usage instructions |
| [JTAG12_J20_J21.md](JTAG12_J20_J21.md) | Pin mapping for the 12 JTAG groups |
| [JTAG_RECOVERY.md](JTAG_RECOVERY.md) | JTAG recovery procedure |
| [SD_RESCUE_JTAG.md](SD_RESCUE_JTAG.md) | SD card rescue |
| [BOOT_WORKFLOW_1027S.md](BOOT_WORKFLOW_1027S.md) | Boot workflow (10.27 s programming) |
| [FLASH_PROGRAMMING_FINDINGS.md](FLASH_PROGRAMMING_FINDINGS.md) | Flash programming findings |
| [CHANNELS12.md](CHANNELS12.md) | 12-channel description |
| [XVC_G1_STATUS.md](XVC_G1_STATUS.md) | G1 channel status records |
| [U20_U22_BUILD.md](U20_U22_BUILD.md) | U20/U22 virtual machine builds |
| [U22_BUILD.md](U22_BUILD.md) | U22 build records |
| [OLED_TEST_STEPS.md](OLED_TEST_STEPS.md) | OLED test steps |

---

## Key Data Quick Reference

### Versions

| Artifact | md5 |
|---|---|
| BOOT.BIN | `835b4152` |
| image.ub | `d8685f59` |
| Bitstream | `7272de42` |
| Server | `d6728f30` |
| xvcinfo | `55a4b777` |

### Addresses

```
0x43C00000 + ch*0x10000   ch0..ch11
0x43CC0000                broadcast engine        TAG 0xA7000000
0x43CD0000                broadcast control block TAG 0xB7000000
```

### Ports

```
2542          broadcast
2543..2554    ch0..ch11
80            web console
```

### Accounts

```
iheper / <password>
root   / <password>
```

### Quality

```
Functional tests  29/29
WNS               +0.307 ns
Methodology       0 violations
LUT               17.02%
FF                7.13%
IO                38.4%
TCK               10 MHz
```

---

## Tests

```bash
python3 xvc/tests/fulltest.py
```

29 checkpoints covering network/web/ports/registers/shift/session/broadcast/self-healing/status.
