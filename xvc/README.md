# XVC Remote Debug Project (AC7Z020 / XC7Z020-2CLG400I)

Following the architecture of the KB article *"Designing an XVC project for Remote
Debugging of Zynq UltraScale+ devices"*, the original UltraScale+/ZCU102 flow was
ported to **Zynq-7000 (ALINX AC7Z020)**: build a PS7 + Debug Bridge + ILA design in
Vivado, produce a bootable image with PetaLinux 2022.2, run an XVC service on the
board, and let Vivado reach the debug resources in the PL over Ethernet.

## What this directory contains now

The tree has grown well past that first port, and the documents below describe the
original one. Three generations of XVC path live here:

| Generation | What it is | Where | State |
|---|---|---|---|
| Debug Bridge + ILA port | the KB port this document walks through (PS7 + `dbg_axi2bscan` + `dbg_bscan2hub` + ILA) | `vivado/build.tcl`, `petalinux/xvc` | works, except ILA-over-XVC ([KI-1](docs/KNOWN_ISSUES.md)) |
| 12-channel production design | 12 `jtag_ctrl` engines + broadcast block, FIFO streaming, `xvcserver_g1`; drives external TAPs, no Debug Bridge | `vivado/build_g1_oled.tcl`, deployed as v24 | verified, on the board |
| Three single-channel projects | `reg` / `fifo` / `dma`, one per transport path, measured side by side | [`vivado/single/`](vivado/single/) | verified end to end, tag `v18` |
| DMA data path | `dma_proxy` kernel module + `xvcserver_dma` | [`kernel/`](kernel/), [`petalinux/dma-merge/`](petalinux/dma-merge/) | verified end to end |

Measured, TCK 10 MHz, same 36 MB image (`test_bits/top.bit`), same bridge and flash
part — the full table with run counts is in the
[top-level README](../README.md#single-channel-comparison-projects):

| Path | 36 MB config | 7 MB bridge | 34.7 MB flash | CPU / word |
|---|---|---|---|---|
| A — register (`single/reg`) | 50.292 s | 16.24 s | 24 min 51 s | 4.96 us |
| B — FIFO (`single/fifo`) | 32.619 s | 12.20 s | 18 min 31 s | ~0.34 us |
| C — DMA (`single/dma`) | 33.377 s | **8.40 s** | 21 min 33 s | 0.57 us |
| HS2 — local USB cable | **30.324 s** | 7.13 s | 14 min 02 s | n/a |

The short version: the DMA path is what makes bulk programming CPU-free, it wins
the few-large-shift workload and loses the many-small-transaction one, and the
local cable still wins every row — XVC buys remote access, not throughput.

The 10 MHz is the common benchmark clock, not the module's ceiling: TCK is
`100 MHz / (2 × DIV)`, the engine is verified at **25 MHz** (`-d 2`, 36 MB in
16.69 s, 2.0× faster), and 50 MHz fails. It also happens to be the only rate
Vivado's XVC client ever requests, which is why the product server stays at
10 MHz even when `-d` is raised — the two servers treat `-d` differently
(`xvcserver_dma` locks it, `xvcserver_g1` caps with it). The
[top-level README](../README.md#speed-hs2-cable-vs-the-three-xvc-paths) has the
measurements.

## Status of the original port (the sections below)

| Item | Status |
|---|---|
| Vivado Block Design / synthesis / implementation / bitstream / XSA | ✅ Done (timing met, LUT 3.54%) |
| PetaLinux project (bootargs / UIO / device tree / xvcserver) | ✅ Done |
| BOOT.BIN + image.ub | ✅ Produced; cold boot from a real board works |
| UIO binding + xvcserver autostart | ✅ Verified on hardware |
| Vivado enumerates the Debug Bridge over XVC | ✅ Verified on hardware (`debug_bridge_0`, IDCODE `0x0A003093`) |
| ILA waveform capture (local JTAG) | ✅ Verified on hardware (counter 0x85→0x8a) |
| 12 JTAG port groups (J20/J21) + 13 TCP ports | ✅ Implemented, synthesized/implemented, on hardware |
| **Vivado displays the ILA over XVC** | ✅ **Works for a device on the XVC chain** — verified for the KU15P (`RBCP_REG/ila64_1`, probe `RBCP_REG/probe0[63:0]`, 1024 samples captured over 2543), see §5.2. ❌ only for the Zynq-**internal** Debug Bridge configuration — that is [KI-1](docs/KNOWN_ISSUES.md#ki-1-ila-not-shown-over-xvc-done-status--0), a `DONE status = 0` detection issue |
| 12-channel design (12 engines + broadcast, FIFO streaming) | ✅ Deployed (v24), `xvcserver_g1` on 2543..2554 |
| Single-channel projects A/B/C | ✅ Built, measured, tag `v18` |
| DMA data path (DDR ↔ shift engine, no CPU per word) | ✅ Verified end to end (36 MB config, 34.7 MB flash) |
| Remote programming of an external KU15P over XVC | ✅ Verified (IDCODE `0x14A56093`, 36 MB in 33.4 s) |

---

## 1. Architecture

```
          ┌──────────────────────────── Zynq-7000 (PS) ──────────────────────────┐
 Vivado   │  Linux: xvcserver  ── /dev/uio0 ── AXI4-Lite ──┐                    │
 hw_server│   ↑ TCP 2542                                    │ @0x43C0_0000       │
 ───XVC───┼───┘                                              ▼                    │
          │                              ┌──────────────────────────────┐        │
          │                              │ Debug Bridge #1              │        │
          │                              │  From_AXI_to_BSCAN           │        │
          │                              │  JTAG fallback = Internal    │        │
          │                              └──────────────┬───────────────┘        │
          │                                             │ m0_bscan               │
          │                              ┌──────────────▼───────────────┐        │
          │                              │ Debug Bridge #2              │        │
          │                              │  From_BSCAN_to_DebugHub      │        │
          │                              │  (contains xsdbm Debug Hub)  │        │
          │                              └──────────────┬───────────────┘        │
          │                                             │                        │
          │                                ┌────────────▼──────────┐             │
          │                                │ System ILA (8 bit)    │← counter    │
          │                                └───────────────────────┘             │
          └─────────────────────────────────────────────────────────────────────┘
```

Key parameters (`vivado/build.tcl`):

| Cell | Configuration |
|---|---|
| `dbg_axi2bscan` | `C_DEBUG_MODE=2` (From_AXI_to_BSCAN), `C_BSCAN_MUX=2` (Internal BSCAN, i.e. the KB's JTAG fallback) |
| `dbg_bscan2hub` | `C_DEBUG_MODE=1` (From_BSCAN_to_DebugHub), `S_BSCAN` ← the former's `m0_bscan` |
| `ila` | `system_ila`, `C_MON_TYPE=NATIVE`, 1 × 8-bit probe, depth 1024 |
| Clock / reset | All `FCLK_CLK0 = 100 MHz` / `proc_sys_reset` |
| PS7 | 565 parameters taken from ALINX's official `ad7606_lwip` example (DDR3 MT41J256M16 32-bit@533 MHz, ENET0 MIO16–27, QSPI MIO1–6, SD0 MIO40–45, UART1 MIO48–49) |

## 2. Directories

| Path | Contents |
|---|---|
| `vivado/build.tcl` | One-shot project/BD/synthesis/implementation/bitstream/XSA (`-tclargs bd\|synth\|full`) |
| `vivado/export.tcl` | Export `.ltx` + `.xsa` from the implemented run |
| `vivado/tcl/ps7_config.tcl` | The 565 PS7 parameters (auto-generated) |
| `vivado/rtl/bscan_tap.v` + `build_ext.tcl` | `C_BSCAN_MUX=3` control experiment (abandoned, see [KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md) KI-1) |
| `vivado/rtl/jtag12_io.v` + `constraints/jtag12.xdc` | 12 JTAG (TCK/TMS/TDI/TDO) port groups mapped to J20/J21 (see [docs/JTAG12_J20_J21.md](docs/JTAG12_J20_J21.md)) |
| `petalinux/xvc` | PetaLinux 2022.2 project (debug-bridge port) |
| `petalinux/apps/xvcserver/xvcserver.c` | XVC server source (derived from XAPP1251 + two fixes) |
| `vivado/single/{reg,fifo,dma,dma64}` | the three single-channel comparison projects (+ the 64-bit word variant), each self-contained with its own `build.tcl` |
| `vivado/build_single.tcl`, `constraints/g1_single.xdc` | shared driver/constraints for the single-channel builds |
| `kernel/` | `dma-proxy` kernel module + bitbake recipe (`inherit module`, autoload) |
| `petalinux/dma-merge/` | 2023.1 overlay for the DMA image: `apply.sh`, DT node, recipe install |
| `tools/xvcserver_dma.c` | single-channel XVC server, DMA + register path (`-m`, `-d <div>`) |
| `tools/dmaprobe.c` | DMA tracing harness used during bring-up |
| `tools/xvc_binary_client.py` | binary XAPP1251 client for measuring a path without Vivado |
| `tools/{regbench,fifobench,w64dma,xvcserver_chunkonly}.c` | per-path benchmarks behind the A/B/C numbers |
| `out/` | Bitstream, XSA, LTX, ILA capture CSVs |
| `out/petalinux/` | BOOT.BIN, image.ub, boot.scr, dtb, backup of the factory BOOT.BIN |
| `sim/` | cocotb + iverilog bit-order regression tests |
| `tools/` | Serial helper, JTAG/XVC connection scripts, on-board debug scripts |
| `docs/` | STATUS.md and design/build documents (vendor doc text is not redistributed) |

## 3. Building

### 3.1 Vivado

```bash
bash -c 'source /opt/Xilinx/Vivado/2022.2/settings64.sh && \
         vivado -mode batch -source xvc/vivado/build.tcl -tclargs full'
```

Measured (`xc7z020clg400-2`): BD validation passes; `All user specified timing constraints are met`;
LUT 1,885 (3.54%), FF 2,822 (2.65%), BRAM 0.5 (0.36%).
Outputs: `out/system_wrapper.bit`, `out/system.xsa` (includes the bitstream), `out/system.ltx`.

### 3.1b Single-channel projects

Each of the three comparison projects is standalone and builds the same way:

```bash
cd xvc/vivado/single/dma            # or reg, fifo, dma64
vivado -mode batch -source build.tcl
```

Outputs land in that project's `out/` (`system_wrapper.bit`, `system.xsa`), which is
gitignored — only the sources are tracked.

### 3.2 PetaLinux (inside a container; environment setup in §7)

```bash
cd xvc/petalinux/xvc
petalinux-config --get-hw-description=<xvc/out> --silentconfig   # already done; saved in the project
petalinux-build
petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
  --fpga images/linux/system.bit --u-boot images/linux/u-boot.elf --force
```

Two PetaLinux projects are involved, and the split matters:

- `petalinux/xvc` (this section) is the **2022.2** project for the debug-bridge port.
- The **12-channel** and **single-channel DMA** images were built with **2023.1**
  (kernel 6.1.5). Their kernel module and recipes are applied by
  [`petalinux/dma-merge/apply.sh`](petalinux/dma-merge/), which drops
  `recipes-modules/dma-proxy`, `recipes-apps/{dmaprobe,xvcserver-dma}` and the DT
  node into an existing 2023.1 project, then appends them to the image. See
  [petalinux/dma-merge/README.md](petalinux/dma-merge/README.md) for the three
  driver defects that had to be fixed before DMA moved a single word.

Configuration highlights (all already baked into the 2022.2 project):

- bootargs: `earlycon console=ttyPS0,115200 clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio`
- rootfs: initramfs (only BOOT.BIN + image.ub are needed)
- Kernel fragments: `CONFIG_UIO=y`, `CONFIG_UIO_PDRV_GENIRQ=y`, `CONFIG_CPU_IDLE is not set`
- Applications: `xvcserver` (C version, started by `/etc/init.d/xvcserver`; the image uses sysvinit)
- Login: `root/root` (password set via extrausers in the bbappend); the init script appends `ttyPS0` to `/etc/securetty`

### 3.3 Deploying

Put `BOOT.BIN`, `image.ub` and `boot.scr` on the first (FAT) partition of the SD card
and power up — it boots automatically.

## 4. Usage

1. After the board boots, `cat /sys/class/uio/uio0/name` → `debug_bridge`; `xvcserver`
   has already started and listens on **2542 (broadcast) + 2543..2554 (channels 0..11)**;
2. Vivado → `Open Target → Open New Target → Connect to Local Server` →
   `Add Xilinx Virtual Cable (XVC)`, enter the board IP and port 2542;
3. `debug_bridge_0` appears in the target; after pointing at `out/system.ltx` you can
   operate the ILA (**currently limited by §6**);
4. Local JTAG can still capture the ILA directly (verified working).

## 5. Measured Results (AC7Z020 hardware)

| Item | Result |
|---|---|
| Cold boot | U-Boot → `boot.scr` → image.ub, no manual intervention |
| Serial login | `root/root` works directly |
| XVC service | Boot log `Starting xvcserver: done`; host `getinfo` → `xvcServer_v1.0:2048` |
| UIO | `/sys/class/uio/uio0/name` → `debug_bridge` |
| JTAG chain | Single device, IDCODE `0x0A003093` (Debug Hub; matches Vivado enumeration) |
| ILA (local JTAG) | `hw_ila_1`, `probe0[7:0]` captured 0x85→0x8a incrementing, see `out/ila_capture_jtag.csv` |
| Network | `eth0 192.168.1.113/24` (DHCP) |
| 12 JTAG port groups | All 48 ports placed & FIXED in BANK34/35, LVCMOS33 (`impl_1/*io_placed.rpt`); 6 groups on J20, 6 on J21 |
| TCP ports | 2542 broadcast → `xvcServer_v1.0:2048`; 2543 channel 0 → same; 2544+ have no engine → connection reset |
| IDCODE (2542 / 2543) | Both read `0x0A003093` |

### 5.1 Current stack (12-channel design + DMA path)

Measured on the deployed v24 image and the single-channel DMA build at the
10 MHz benchmark clock (the engine runs to 25 MHz — see above), against the
external XCKU15P (IDCODE `0x14A56093`):

| Item | Result |
|---|---|
| Shift rate, register path (A) | 7.55 Mbit/s (chunk-limited, `0x28` DONE counter verified) |
| Shift rate, FIFO (B) / DMA (C) | 9.97 / 9.94 Mbit/s — 99.4–99.7% of the 10 MHz wire |
| 36 MB configuration | A 50.292 s, B 32.619 s, C **33.377 s**, HS2 cable 30.324 s |
| SPI bridge download, 7 MB | A 16.24 s, B 12.20 s, C **8.40 s**, HS2 7.13 s |
| Flash erase+program+verify, 34.7 MB | A 24:51, B 18:31, C 21:33, HS2 14:02 |
| CPU per 32-bit word | A 4.96 us, B ~0.34 us, C 0.57 us (15.5% duty) |
| DMA correctness | 563 transfers, `pop == words` exactly, 0 drops, `DMASR = 0x1002` |
| Register-path fallback | none on the DMA build (`chunk_bits = 0`) |

### 5.2 ILA over XVC (verified)

Remote ILA viewing does work with this stack — the earlier ❌ was about the
Zynq-internal Debug Bridge port, not about ILA-over-XVC in general. Verified
2026-11-15 against the KU15P on the external chain, through `xvcserver_g1` on
2543 at 10 MHz:

```
open_hw_target -xvc_url 192.168.1.113:2543
set_property PROBES.FILE test_bits/top.ltx [current_hw_device]
refresh_hw_device -update_hw_probes true
get_hw_ilas                      -> hw_ila_1
get_hw_probes -of_objects hw_ila_1 -> RBCP_REG/probe0
run_hw_ila / wait_on_hw_ila / upload_hw_ila_data
write_hw_ila_data -csv_file ...  -> 1024 samples
```

The captured CSV is [docs/ila_over_xvc.csv](docs/ila_over_xvc.csv) (27 KB, 1024
samples of a 64-bit probe). The server log for that session shows the shift
traffic (`cmd=sh` repeated, then `client closed`), so the data path is the XVC
server, not the local cable. The probe happens to read constant zero in this
test (the monitored net is idle in the `top.bit` design), which does not change
what it demonstrates: the debug hub round-trip — core enumeration, arm, capture,
upload — completes over XVC.

Two things the numbers do not say, and should: C does **not** beat B end to end
(2.3% slower, ~1.7x B's CPU) — its value is CPU offload and few-large-shift
workloads — and neither beats the local cable, because XVC pays a protocol round
trip the cable does not.

## 6. Known Issues

Details (symptoms, eliminated hypotheses, workarounds) live in a separate document:
**[docs/KNOWN_ISSUES.md](docs/KNOWN_ISSUES.md)**

Summary:

| ID | Issue | Status |
|---|---|---|
| KI-1 | Vivado cannot see the ILA over XVC (`DONE status = 0`) | **Not fixed, but narrowly scoped**: it is specific to the Zynq-**internal** Debug Bridge configuration. ILA over XVC itself works for a device on the chain — verified on the KU15P, see §5.2. Workaround for the internal case remains ILA over local JTAG |
| KI-2 | After loading a bitstream with a JTAG cable, XVC often cannot connect | Diagnosed (BSCAN mux latch); let the FSBL configure the PL |
| KI-3 | Host Ubuntu 26.04 cannot build PetaLinux 2022.2 directly | Worked around with a container (see §7) |

## 7. Containerized Build (when the host is not a supported distribution)

This machine runs Ubuntu 26.04 / glibc 2.43 / GCC 15, outside PetaLinux 2022.2's
validated range: bitbake's fakeroot worker fails to start, so the build runs in an
Ubuntu 22.04 container.

```bash
docker run -d --name plnx --privileged \
  -v /opt/Xilinx:/opt/Xilinx:ro -v "$PWD":/work -w /work ubuntu:22.04 sleep infinity

docker exec plnx bash -c 'apt-get update && apt-get install -y \
  build-essential gcc g++ make python3 python3-git python3-jinja2 python3-pexpect \
  python3-subunit git wget diffstat unzip chrpath socat libssl-dev libncurses5-dev \
  zlib1g-dev zlib1g:i386 libc6-dev-i386 lib32z1 libselinux1 xz-utils debianutils \
  iputils-ping cpio file rsync bc bzip2 flex xterm net-tools locales xvfb x11-utils && \
  locale-gen en_US.UTF-8 && useradd -u 1000 -m builder && chown -R 1000:1000 /work'

docker exec plnx bash -c 'Xvfb :99 -ac &'          # xsct(HSI) needs a display

docker exec -u 1000 -e HOME=/home/builder -e DISPLAY=:99 -e LANG=en_US.UTF-8 \
  plnx bash -lc 'cd /work/xvc/petalinux/xvc && \
  source /opt/Xilinx/petalinux/2022.2/settings.sh && \
  petalinux-build && petalinux-package --boot \
    --fsbl images/linux/zynq_fsbl.elf --fpga images/linux/system.bit \
    --u-boot images/linux/u-boot.elf --force'
```

Three mandatory pitfalls: `x11-utils`/`xvfb`/`locale` (otherwise xsct will not
start), **never run bitbake as root** (create a uid 1000 user), and when the project
lives under `/run/media/...` remove `/run/` from `PSEUDO_IGNORE_PATHS`
(see `petalinux/xvc/project-spec/meta-user/conf/petalinuxbsp.conf`).

## 8. Offline Regression (cocotb)

```bash
cd xvc/sim && PATH=$PWD/.venv/bin:$PATH make
# test_xvc_shift.idcode_over_32bit_chunks  PASS
```

`sim/rtl/jtag_tap.v` is a minimal TAP model; `sim/test_xvc_shift.py` drives it with
the same 32-bit chunking / LSB-first scheme as `xvcserver.c` and reads the IDCODE
back — if the bit order breaks, simulation goes red before any hardware is involved.

## 9. Differences from the Original Article

| Item | KB (UltraScale+) | This project (Zynq-7000) |
|---|---|---|
| Device / board | ZCU102, xczu9eg | AC7Z020, xc7z020clg400-2 |
| PS configuration | ZCU102 preset | ALINX's official 565 PS7 parameters |
| UIO index | Hard-coded `uio1` | Scan `/sys/class/uio/*/name` for `debug_bridge` |
| Boot | SD rootfs | initramfs (BOOT.BIN + image.ub) |
| Service | Run manually | sysvinit autostart + `/etc/securetty` fix |
| Toolchain | Vivado/PetaLinux 2018.3 | 2022.2 |

## 10. References

> This repository **no longer redistributes** AMD/Xilinx document text or extracts
> (for copyright reasons). Download them from AMD:

- **PG245** — *Debug Bridge v2.0* (AXI Debug Bridge IP)
- **XAPP1251** — *Xilinx Virtual Cable Running on Zynq-7000*
- **UG908** — *Vivado Programming and Debugging*
- **UG470** — *7 Series FPGAs Configuration User Guide*

Local design documents:

- [`docs/STATUS.md`](docs/STATUS.md) — per-item status, verified/excluded list
- [`docs/KNOWN_ISSUES.md`](docs/KNOWN_ISSUES.md) — known issues (34 entries with root causes)
- [`docs/MANUFACTURING.md`](docs/MANUFACTURING.md) — factory programming work instruction
- [`docs/DMA_BRINGUP.md`](docs/DMA_BRINGUP.md) — the DMA bring-up trace and the stale-bitstream root cause
- [`docs/CHANNELS12.md`](docs/CHANNELS12.md) — the 12-engine + broadcast design
- [`docs/BUILD_2023_1_FINDINGS.md`](docs/BUILD_2023_1_FINDINGS.md) — PetaLinux 2023.1 build notes
- [`petalinux/dma-merge/README.md`](petalinux/dma-merge/README.md) — the DMA image overlay and its defect history
