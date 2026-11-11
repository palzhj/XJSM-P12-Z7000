# AC7Z020 XVC Remote Debug System — Complete Development and Debug Process

Date: October 2026 · Platform: AC7Z020 (XC7Z020-2CLG400) + external AMD Xilinx FPGA chain
Goal: implement an XVC 1.0 server in the Zynq PL so that, over Ethernet, it can identify,
read the status of, and program the FPGA chain attached to J20 (G1), replacing the USB JTAG cable.

---

## 1. Final Results

> **Final state as of 2026-10-29**
>
> | Item | Result |
> |---|---|
> | XVC programming | ✅ `PROGRAM_OK`, **18.5 s** (6/6 successful) |
> | First success | 23.8 s (2026-10-29 15:20) |
> | USB cable baseline | 9.56 s |
> | Efficiency | 49.5% (9.2 s at the 10 MHz TCK limit) |
> | Scan reliability | 8 retries, failure probability ~1.5e-5 |
>
> Root causes (in order of discovery):
> 1. `getinfo` declared a maximum shift of 65536, but Vivado actually requested **523,511 bits** → judged over-limit and disconnected (**programming could never succeed**);
> 2. `petalinux-build` overwrites `images/linux/system.bit` with an old XSA → **the board kept running the old PL**;
> 3. The server wrote DIV to `0x18` (read-only STATUS), while the real DIV is at `0x14` → **TCK never reached 10 MHz**;
> 4. Flashing `image.ub` failed silently → the board kept running an old server for a long time, creating the illusion of a "fixed 3-second stall".


| Metric | Result |
|---|---|
| XVC protocol | v1.0, `getinfo` / `settck` / `shift`, max 4 Mbit per packet |
| Chain identification | `A7=0x0362C093`, `K7=0x43651093` (matches the USB cable) |
| **Bitstream programming** | ✅ `PROGRAM_OK`, `End of startup status: HIGH` |
| Programming duration | 23.8 s (USB cable baseline 9.56 s) |
| Data integrity | 60,000-bit BYPASS passthrough with 0 bit errors |
| Network integrity | 32 MB random file MD5 matches, NIC errors=0 |
| TCK | 10 MHz by default (`-d 5`), can be slowed via `settck` |

---

## 2. System Composition

```
┌──────────────┐   TCP 2543    ┌────────────────────────────┐
│  PC / Vivado │ ────────────► │ Zynq PS: xvcserver (Linux) │
│ hw_server    │ ◄──────────── │   /dev/mem @0x43C00000     │
└──────────────┘               └─────────────┬──────────────┘
                                             │ AXI4-Lite
                                 ┌───────────▼────────────┐
                                 │ PL: jtag_ctrl (RTL)    │
                                 │  + system_ila (debug)  │
                                 └───────────┬────────────┘
                                             │ TCK/TMS/TDI/TDO
                                 ┌───────────▼────────────┐
                                 │ J20 G1 → K7 + A7 chain │
                                 └────────────────────────┘
```

### Key Files

| Category | Path |
|---|---|
| AXI-Lite JTAG controller RTL | `vivado/rtl/jtag_ctrl.v` |
| Minimal system build script | `vivado/build_g1.tcl` |
| Pin constraints (G1) | `vivado/constraints/g1.xdc` |
| XVC server (C, Linux user space) | `petalinux/apps/xvcserver_g1/xvcserver_g1.c` |
| PetaLinux recipe | `petalinux/xvc/project-spec/meta-user/recipes-apps/xvcserver/` |
| Programming script (XVC) | `tools/vivado_program_final.tcl` |
| Cable programming baseline | `tools/program_cable2.tcl` |
| Diagnostic tools | `tools/` (see Section 7 for details) |

---

## 3. Hardware Design (PL)

### 3.1 JTAG Controller Registers (AXI4-Lite, base address 0x43C00000)

| Offset | Name | Description |
|---|---|---|
| 0x00 | LENGTH | Number of bits in this shift (≤32) |
| 0x04 | TMS | TMS bit vector |
| 0x08 | TDI | TDI bit vector |
| 0x0C | TDO | Read back TDO |
| 0x10 | CTRL | bit0 start (self-clearing), bit1 busy |
| 0x14 | STATUS | Busy flag |
| 0x18 | DIV | TCK divider: f = 100 MHz / (2 × DIV) |

### 3.2 Shift Engine (final version)

Single phase counter `ph: 0 .. 2*div-1`:

- `ph == 0`: set up TMS/TDI, TCK held low
- `ph == div`: TCK rising edge (the only one)
- `ph == div + div/2`: sample TDO (midpoint of the high phase)
- `ph == 2*div-1`: TCK falling edge, advance to the next bit

Exactly one rising edge per bit, verified by ILA measurement (a 25-bit sequence = 25 rising edges).

### 3.3 ILA Debug Facilities

`system_ila` with four 1-bit probes, connected to `tck / tms / tdi / tdo` respectively,
sampling at 100 MHz with a depth of 16384. Used to capture real JTAG waveforms (a key technique in this project).

---

## 4. Software Development Process

### Phase 1: Minimal System
PS7 (UART + Ethernet + SD) + AXI Interconnect 1×1 + a custom `jtag_ctrl`,
address fixed at 0x43C00000, pins routed through J20 (R14/P14/U12/T12), with PULLUP/PULLDOWN added in the constraints.

### Phase 2: PetaLinux
PetaLinux 2022.2 (container `plnx2`, Ubuntu 22.04):
- Device tree, FSBL, U-Boot and rootfs are all generated from `system.xsa`;
- A custom recipe builds `xvcserver` and installs it into `/usr/bin`;
- An init script starts it at boot: `xvcserver -a 0x43C00000 -d 5 &`
- Artifacts: `BOOT.BIN` (including the bitstream) + `image.ub`

### Phase 3: XVC Server
Linux user-space program that maps the AXI registers through `/dev/mem`:

1. `getinfo:` → returns `xvcServer_v1.0:<maxbits>\n`
2. `settck:<ns>` → computes DIV = ns/20, echoes back the actual period as 4 bytes
3. `shift:<bits><tms[]><tdi[]>` → drives the hardware in 32-bit chunks, returns TDO

Uses fork-per-client + an `flock` bus lock, allowing concurrent connections while serializing JTAG access.

### Phase 4: Debug Facilities
- Server dump mode (`-l file`): records the length, TMS, TDI and TDO of every shift
- ILA capture scripts, BYPASS verification, status reads, packet-capture proxy, etc.

---

## 5. Debug Process (Timeline)

### 5.1 Initial Symptoms
- IDCODE reads correctly (both devices are right)
- Vivado can enumerate devices over XVC
- **Programming always fails**: `[Labtools 27-3165] End of startup status: LOW`

### 5.2 Investigation Item by Item (in order)

| # | Hypothesis | Verification method | Conclusion |
|---|---|---|---|
| 1 | Byte-level chunking causes bit misalignment | 9/16/43-bit comparison | ❌ Reproduced and fixed (chunk by bit) |
| 2 | TDO high bits misaligned on short shifts | 8/16/24/43-bit comparison | ❌ Fixed `r >>= (32-chunk)` |
| 3 | Insufficient buffer | Increased to 3×, 65536 bits | ❌ Partial improvement |
| 4 | `go_seq` 8-bit wraparound | 256-shift test | ❌ Changed to 32 bits |
| 5 | Concurrent bus driving | Dual-connection test | ❌ Added flock |
| 6 | TCP short read | Large-payload shift | ❌ Changed to `read_full` |
| 7 | TCP short write | Large TDO response | ❌ Changed to `write_full` + 1 MB buffer |
| 8 | Network bit errors | 32 MB MD5 | ✅ No errors |
| 9 | JTAG data path | BYPASS 60k bits | ✅ 0 errors |
| 10 | Vivado cannot open the XVC target | Tcl batch mode | ❌ Root cause was `HOME` not writable |
| 11 | Invalid IR scan | Send bit by bit | ❌ Overturned by a later conclusion |
| 12 | Abnormal IR length (L≡2 mod 3) | L=4..24 scan | ❌ An artifact caused by the disconnects |
| 13 | Shift engine phase | Rewrote the engine + simulation | ⚠️ Improvement, but not the root cause |
| 14 | ILA waveform capture | 4 probes + trigger | ✅ Captured TMS/TDI/TDO, all correct |
| 15 | **Single shift too large** | Server log `L <len>` | ✅ **Root cause** |

### 5.3 The Turning Point

Repeated packet captures and waveform captures all proved the on-wire data was correct, yet programming still failed. In the end, after adding a
**per-shift length log** to the server, one dump immediately showed the answer:

```
L 7131
L 7131
L 10018
L 100136
L 523511     ← far beyond the declared 65536
```

And in the server code:

```c
if (len <= 0 || len > XVC_MAX_BITS || ...) return 1;   /* close the connection outright */
```

So the moment Vivado sent a 523,511-bit packet, **the connection was closed immediately**. On the Vivado side this showed up as
"target disappeared / not ready", not a single byte of the bitstream was ever sent (the dump held only 3.5 KB even for the large blocks),
and it finally reported `End of startup status: LOW`.

This explains all the earlier anomalies:
- Why the waveforms "looked" correct yet nothing could be programmed — because execution never even reached the point of sending data;
- Why IR read-back and length scans gave bizarre results — the chain state was different after every disconnect.

### 5.4 Fix and Verification

| Item | Change |
|---|---|
| `XVC_MAX_BITS` | 65536 → **4194304** (4 Mbit) |
| Buffer | 24 KB static → 1.5 MB |
| Length log | Added `L <len>` records |

Verification:

```
TARGET: xc7k325t_0
INFO: [Labtools 27-3164] End of startup status: HIGH
PROGRAM_OK in 23821 ms
```

Two consecutive programming runs both succeeded.

---

## 6. Summary of Fixed Defects

| # | Defect | Impact | Fix |
|---|---|---|---|
| 1 | AXI slave with multiple drivers | Not synthesizable / erratic behavior | Rewritten with a single driver |
| 2 | Shifts rounded to bytes | Misalignment for lengths not a multiple of 8 | Exact bit-level chunking |
| 3 | TDO right-shift padding | High bits wrong on short shifts | `r >>= (32-chunk)` |
| 4 | Buffer 2× / limit 2048 | Large shifts rejected | 3× → 4 Mbit |
| 5 | `go_seq` 8-bit | One beat lost every 256 | 32-bit |
| 6 | Concurrent bus driving | Data corruption | `flock` bus lock |
| 7 | TCP short read | Disconnects on large payloads | `read_full` |
| 8 | TCP short write | TDO truncated | `write_full` + 1 MB socket buffer |
| 9 | **Max packet 65536** | **Programming could never succeed** | **4 Mbit** |
| 10 | Vivado Tcl cannot open XVC | No automation possible | `HOME` pointed at a writable directory |
| 11 | Shift engine phase | Potential timing risk | Rewritten with explicit TCK edges |

---

## 7. Diagnostic Tool Index

| Tool | Purpose |
|---|---|
| `tools/vivado_program_final.tcl` | XVC programming (production use) |
| `tools/program_cable2.tcl` | USB cable programming baseline |
| `tools/ir_loop.py` / `combined_loop.py` | Generate IR / combined sequences for ILA capture |
| `tools/ila_arm.tcl` / `ila_cap4.tcl` | ILA arm, trigger, export CSV |
| `tools/bypass_check.py` | BYPASS data integrity check |
| `tools/status_read.py` | Read the CFG_OUT status register |
| `tools/xvc_proxy.py` | XVC packet-capture proxy (text + binary) |
| `tools/serial_peek.py` | Serial session helper |

---

## 8. Reproduction Steps

```bash
# 1. Build the PL
vivado -mode batch -source xvc/vivado/build_g1.tcl

# 2. Package BOOT.BIN
petalinux-package --boot --fsbl zynq_fsbl.elf \
    --fpga system_wrapper.bit --u-boot u-boot.elf

# 3. After the board boots, confirm the service
/usr/bin/xvcserver -a 0x43C00000 -d 5 &

# 4. Program
vivado -mode batch -source xvc/tools/vivado_program_final.tcl
```

---

## 8.5. Programming Duration Records

Every programming run is recorded to `logs/program_timing.csv`, and `tools/program_and_log.sh`
appends automatically:

```bash
./xvc/tools/program_and_log.sh test_bits/top-with-auto-neg.bit 10 "note"
```

Existing records:

| Time | Method | PL version | TCK | Engine | Result | Duration |
|---|---|---|---|---|---|---|
| 15:0x | USB cable | - | - | - | OK | 9564 ms |
| 15:20 | XVC | rev1 | 10 MHz | 32bit | OK | 23821 ms |
| 15:33 | XVC | rev1 | 10 MHz | 32bit + coarse polling | OK | 23702 ms |
| 16:30 | XVC | rev2(0xA5) | 10 MHz | 32bit + skip duplicate writes | OK | 22589 ms |
| 16:41 | XVC | rev2(0xA5) | 10 MHz | 32bit + skip duplicate writes | OK | 22634 ms |

### FIFO Streaming Optimization (rev3)

Three registers are added on AXI-Lite (0x1C TXD / 0x20 RXD / 0x24 STATUS) along with
128×32bit TX/RX FIFOs, so the CPU needs only 1 write + 1 read per 32 bits:

| Version | Engine | Duration | Speedup |
|---|---|---|---|
| rev2 | 32bit register path | 22.57 s | baseline |
| **rev3** | **32bit + FIFO streaming** | **15.68 s** | **1.44×** |

Streaming is used only for large blocks with consecutive TMS=0 and length ≥ 8192 bits (configuration data);
small operations such as scans and IR still use the proven register path.

> **Note**: in later retesting the streaming path showed **occasional hangs** (RX FIFO contention),
> so it is disabled by default in the code (`FIFO_MIN = 0x7FFFFFFF`), with the implementation retained pending a fix.
> The stable, usable configuration is the 32-bit register path (22.6 s).

When a connection ends, the server also prints statistics for that session:

```
STAT bits=91549696 elapsed=22500 ms rate=4.07 Mbit/s
```

## 9. Lessons Learned

1. **Look at the protocol layer before the waveforms**: 90% of the debug time on this project went into waveforms and the data path,
   while the root cause was a protocol-layer limit in which "a rejected request silently drops the connection". Had **the length of
   each request** been logged from the very start, it would have taken only minutes to localize.
2. **Disconnects create illusions**: once the connection is closed, every subsequent scan runs in a different chain state,
   which is how phenomena like "IR length L≡2 (mod 3) is required" appeared — they look regular but are actually meaningless.
3. **ILA is valuable, but it must be used correctly**: first confirm there really is activity inside the trigger window, otherwise
   "did not capture" gets misjudged as "the signal is wrong".
4. **XVC maxbits must be scaled to what the client actually needs**: Vivado requests single shifts far beyond typical values
   (523,511 bits in this case), and declaring too small a value causes silent failure.
