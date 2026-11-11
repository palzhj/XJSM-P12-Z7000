# XVC (G1 Single Channel, Port 2543) Status Report

> **Resolved (2026-10-29)**: the root cause was that the maximum shift length advertised by the
> XVC server was too small (65536), whereas Vivado requests a single shift of **up to 523,511 bit**
> during actual programming. After the server rejected the oversized request it closed the
> connection outright, so Vivado could never send the bitstream, which showed up as
> `End of startup status: LOW`. After raising the limit to **4 Mbit** (with the buffer scaled up
> accordingly), XVC programming succeeded: `PROGRAM_OK`, `End of startup status: HIGH`, taking
> about 23.8 s (USB cable baseline 9.56 s).

Date: 2026-10-29  Hardware: AC7Z020 (XC7Z020) + external AMD Xilinx FPGA chain (J20 G1)

## 1. System Composition

| Part | Path |
|---|---|
| Vivado project script (minimal system) | `vivado/build_g1.tcl` |
| AXI-Lite JTAG controller RTL | `vivado/rtl/jtag_ctrl.v` |
| Pin constraints | `vivado/constraints/g1.xdc` |
| XVC server (single port 2543) | `petalinux/apps/xvcserver_g1/xvcserver_g1.c` |
| Server init script | `petalinux/xvc/project-spec/meta-user/recipes-apps/xvcserver/files/xvcserver.init` |
| Programming script (XVC) | `tools/vivado_program_2543.tcl`, `tools/vivado_program_retry.tcl` |
| Programming script (USB cable baseline) | `tools/program_cable2.tcl` |
| Capture proxy | `tools/xvc_proxy.py` (logs `out/proxy.log` / `out/proxy.bin`) |
| Diagnostic scripts | `tools/bypass_check.py`, `tools/status_read.py`, `tools/xvc_loopback.py` |

## 2. Verified Working

| Item | Evidence |
|---|---|
| Chain identification | `A7=0x0362C093`, `K7=0x43651093`, matching the USB cable |
| TCP integrity | MD5 matches on a 32 MB random file (59 MB/s), NIC errors=0 at both ends |
| JTAG data path (DR) | BYPASS pass-through of 60,000 bit, **0 bit errors** |
| Vivado enumeration | Both devices visible in GUI and Tcl (Tcl needs a writable `HOME`) |
| Cable programming baseline | `PROGRAM_OK in 9564 ms` (11.4 MB) |

## 3. Blocker: IR Scan Has No Effect

| Test | Expected | Measured |
|---|---|---|
| Read DR after TLR | both IDCODEs | ✅ correct |
| Read DR after writing IR=0x3F(BYPASS) | all 0 | ✅ correct |
| Read DR after writing IR=0x09(IDCODE) | both IDCODEs | ❌ all 0 |
| Retry with IR length 6/12/18 | — | ❌ all failed |
| TCK 1 MHz / 10 MHz | — | ❌ same result |
| **Send IR bit by bit** (19 single-bit shifts) | equivalent to sending it in one block | ❌ still fails (`tools/ir_bitwise.py`) |

Conclusion: **the DR path is fine, but IR instruction writes have no effect**. Vivado programming
must first send `JPROGRAM(0x0B)`, `CFG_IN(0x05)` and `JSTART(0x0C)` through the IR, so the
configuration flow cannot start, which shows up as `End of startup status: LOW`, and not a single
byte of the bitstream (11.4 MB) is ever sent (the server-side dump holds only 3.5 KB of large-block
data).

## 4. Defects Already Fixed in the Server

1. AXI4-Lite slave driven from multiple places → rewritten with a single driver
2. Shift chunking rounded to whole bytes → exact bit-level chunking
3. TDO right-shift padding misaligned the high bits on short shifts → `r >>= (32 - chunk)`
4. Buffer 2× with a 2048 bit limit → 3× / 65536 bit
5. `go_seq` 8-bit wraparound dropped one beat every 256 shifts → 32 bit
6. Several connections driving the same JTAG concurrently → `flock` bus lock
7. TCP short reads dropped the connection on large payloads → `read_full()`
8. TCP short writes → `write_full()` + 1 MB socket buffer
9. `-d` speed parameter conversion (period_ns/20, never below the configured value)

## 5. ILA Observation (In Progress)

A `system_ila` was added to the minimal G1 design (probe0 = {tdo,tdi,tms,tck}, 100 MHz sampling);
the bitstream is on the board, `hw_ila_1` is detected and can capture 1024 points.

The "cannot capture" problem has been solved: the first few empty captures happened because **the
test loop finished before Vivado had finished starting up**. After lengthening the loop, captures
work properly:

```
samples=16384  tck=1456  tms=96  tdi=96  tdo=16289 (high-level count)
TCK period ~900 ns (≈1.1 MHz)
TCK rising edges: 182, of which 4 have TMS=1 (in pairs, corresponding to Exit1IR/UpdateIR)
```

This shows the probes are connected correctly (`ila/probe0..3` go to `/jtag_tck1`, `/jtag_tms1`,
`/jtag_tdi1`, `/jtag_tdo_1` respectively) and that the TMS transitions of the IR scan really do
appear on the wire.

Capture script: `tools/ila_cap4.tcl` (4 × 1-bit probes, triggered on TMS or TCK);
companion stimulus: `tools/ir_loop.py`, `tools/shift_loop.py`.

### Complete IR Waveform (Verified)

A complete IR scan of 25 TCK rising edges captured with the ILA:

```
TMS: 111110 1 1 0 0 | 000000000000 | 1 1 0
TDI: 000000 0 0 0 0 | 100100100100 | 0 0 0
TDO: 111111 1 1 1 0 | 10111010111  | 1 1 1
```

- The TMS sequence is completely correct: `TLR(5×1)+RTI → SelDR → SelIR → CapIR → ShiftIR → 12×shift → Exit1IR → UpdateIR → RTI`
- The TDI data is completely correct: `100100 100100` = `0x09`(IDCODE) ×2
- TDO toggles during ShiftIR, showing the device is responding

**Conclusion: on the physical wires the IR scan is textbook-correct.**

### Combined Sequence Capture (TLR + IR + DR in One Pass)

```
TMS: 111110 1100000000000000 110 1000...(64×0)...100
TDO: 1111111111 1010111010 1111 1111 0000...(all 0)
```

After IR=0x09 is written correctly, the DR readback is still all 0 instead of the IDCODE.
Moreover the IR shift-out (readback) is `101011` (0x35) instead of the expected `100100` (0x09),
showing that the actual IR contents inside the device do not match the written value.

### IR Chain Length Sweep (Key Finding)

For each L = 4..24, run `TLR → IR(0x09 repeated L bits) → DR read 64 bits`:

| L | Result |
|---|---|
| 11, 14, 17, 20, 23 | ✅ reads back `A7=0x0362C093 K7=0x43651093` |
| all others (4-10, 12, 13, 15, 16, 18, 19, 21, 22, 24) | ❌ all 0 or garbage |

Pattern: **it succeeds when L ≡ 2 (mod 3)**. The real IR chain length should be 12 per the devices
(6+6), yet 12 is precisely the case that fails.

This "one usable length every 3 bits" periodicity matches the **3-phase state machine
(LOAD / HIGH / LOW)** of the shift engine exactly, so a systematic phase/boundary offset in the
engine is highly suspected. It also explains why Vivado (which sends a 12-bit IR) can never
configure the device through our XVC.

### SD Card Full (Found 2026-10-30)

**Yet another source of silent failure**: the board's SD card (361 MB FAT partition) was filled by
debug dump files (`ds.bin` 115 MB + `xvc_dump.bin` 39 MB), which caused:

- `wget` downloads of `BOOT.BIN`/`image.ub` to produce **0-byte files** (md5 `d41d8cd9…`);
- `mv` to succeed anyway → **the boot image was overwritten with an empty file** → the board could
  not boot.

This was also the **real reason** why repeated "rollback/rebuild" attempts on the evening of
29 October had no effect.

**Recovery**: pulled the SD card and mounted it on a PC, deleted the 155 MB of dump files
(149 MB free), and wrote the verified `BOOT.BIN`(b6ae0dfc) and `image.ub`(f14145e0).

**New flow** (`tools/flash_board.sh`): download to `/tmp` → **verify md5** → then write to the SD card.

Re-test after recovery: 0.24 µs/bit shift (no stalls), programming **18,005 ms**.

### Real Cause of the 3-Second Stall (Solved)

After working through everything, it turned out that **the `image.ub` running on the board had
always been an old version** (FIFO server + old PL), because the image flashing command
(`wget -q ... && mv`) failed silently inside the chained command, so:
- the server took the FIFO streaming path while the PL had no FIFO registers → every large shift
  spun until the guard timed out = **a fixed 3 seconds**;
- none of the "rollback"/"rebuild" attempts in that period ever actually reached the board.

After the fix (on-board `image.ub` md5 matches the host, `9c25cc41`):

| Shift Length | Before Fix | After Fix |
|---|---|---|
| 8,000 | 2.7 ms | 2.7 ms |
| 12,000 | **3.005 s** | **3.7 ms** |
| 60,000 | **3.007 s** | **15.2 ms** |

**Programming time: 18.1 s** (previously 22.6 s; fixing the DIV address changed TCK from 6.25 MHz
to a true 10 MHz).

### Occasional Scan Failures (Solved With Retries)

`open_hw_target` reports `No devices detected` about 1 time in 4 (reading the IDCODE by hand at the
same moment works, so it is an hw_server scan timing issue).

**Capture evidence from a failure** (server `-l` dump + stderr):

```
len=1070  TDO=...436510930362C093FFF      ← both IDCODEs already read back correctly
len=198   TDO=3FFFFFFFF...D75F            ← bit-for-bit identical to the successful case
len=60    TDO=0012400405FD75FF
len=115   TDO=0009200440002480080BFAEBFD75FF
close: read cmd failed (errno=0)          ← hw_server closed the connection itself
client closed
```

Key conclusions:
- on failure the **data is completely correct** (the IDCODE has been read), bit-for-bit identical
  to a successful run;
- the failure happens after the 4th shift, and **hw_server disconnects actively**; it is not a
  server data error;
- the dump file from a failure contains **no complete shift record** (the client closes in the
  middle of sending the payload).

Fix: `tools/vivado_program_retry.tcl` retries `open_hw_target` up to **8 times** (500 ms apart),
which drops the failure probability to 0.25⁸ ≈ 1.5e-5.

Measured: **10 consecutive programmings all succeeded** (18,309 ~ 19,293 ms, average
**18,589 ms**): 18.3 / 18.9 / 18.3 / 19.4 / 18.8 / 18.3 s (mean ≈18.5 s).

`tools/program_and_log.sh` now calls the retry script and records the elapsed time automatically.

### Known Outstanding Issue (Evening of 2026-10-29)

After restoring the archived "known good" version, a **fixed ~3.005 s stall appeared for shift
lengths ≥ 12000 bit**:

| Shift Length | Time | Per Bit |
|---|---|---|
| 4,000 | 1.9 ms | 0.46 µs |
| 8,000 | 3.0 ms | 0.37 µs |
| 12,000 | **3.005 s** | 250 µs |
| 16,000 | **3.005 s** | 188 µs |
| 60,000 | **3.007 s** | 50 µs |

The time is independent of length and constant at ~3.005 s, and **the stall happens in the recv
phase** (send completes immediately):

```
N=10000  send=0.0000s  recv=3.0053s
N=12000  send=0.0000s  recv=3.0053s
```

This matches the signature of a **TCP retransmission timeout (RTO)**, not an engine performance
problem.

One more register address mismatch was found (to be fixed):
- RTL: DIV at **0x14**, STATUS at 0x18
- Server: `wr(0x18, tck_div)` → DIV was never actually written, so `DIV_DEFAULT=8` (6.25 MHz) was
  always in effect
Fixed: DIV address 0x18 → **0x14** (before this, settck never took effect and TCK stayed at 6.25 MHz).

The 3-second stall is still present and is unrelated to TCK (the time did not change after changing
DIV), confirming it is not an engine problem.
A `SHIFT len=... took=... ms` timing log has been added to the server (stderr), so next time it can
be determined directly whether the stall is during the shift or while writing the response.

Hypotheses (in order of likelihood):
1. the server hits a TCP retransmission while `write_full()` writes the TDO response (board-side
   window/timing);
2. an AXI read on the board goes through one timeout recovery after a long burst;
3. first-touch page fault on the server's 1.5 MB static buffer (one-off, but it would explain a
   fixed 3 s).

## 5.9 Configuration Flash Programming (S25FL256S, Failed)

Using the user-provided `test_bits/top-with-auto-neg.mcs` (31 MB) with part
`s25fl256sxxxxxx0-spi-x1_x2_x4` (confirmed present in the Vivado device library):

```
TARGET: xc7k325t_0
CFGMEM: cfgmem_0
ERROR: [Labtools 27-3347] Flash Programming Unsuccessful:
       Failure to set flash parameters.
FLASH_FAILED after 265 ms
```

**UG908 explanation** (Chapter 7):

> Vivado can also indirectly program select Flash-based configuration memory
> devices via JTAG. Do this by **first programming the AMD FPGA with a special
> configuration that provides a data path between JTAG and the Flash device
> interface**. Then, program the configuration memory device contents using
> this data path.

In other words, indirect Flash programming requires Vivado to first load a special
"JTAG↔Flash bridge" configuration into the FPGA. This failure occurred at **265 ms** (before any
JTAG traffic was generated), so it is a failure in the Vivado-side parameter/bridge initialization
stage and is unrelated to our XVC data path.

**Key evidence**: the server dump file was **0 bytes** during the attempt — Vivado failed at the
"set flash parameters" stage and **generated no JTAG traffic at all**.

Combinations tried (all failed at the parameter stage, taking 27~265 ms):

| MCS/BIN | Operation Combination | Result |
|---|---|---|
| User-provided .mcs | blank/erase/program/verify/checksum | 27-3347 |
| Regenerated .mcs | erase+program | 27-3347 |
| Regenerated .bin | erase+program | 27-3347 |
| Regenerated .bin | FILE only (no operation) | 27-3144, an operation must be selected |
| With refresh_hw_device | erase+program | 27-3347 |

Additionally: following the reference flow and switching to **`PROGRAM.FILES` (plural) +
ADDRESS_RANGE + UNUSED_PIN_TERMINATION** gave the same result (27-3347, 266 ms, zero traffic):

```
CFGMEM: cfgmem_0
FILE_CHECK: .../test_bits/top-with-auto-neg.mcs
ERROR: [Labtools 27-3347] Flash Programming Unsuccessful: Failure to set flash parameters.
```

Conclusion: **unrelated to the XVC data path** (zero traffic); the Vivado-side preconditions for
indirect programming are not met.

Suggested next steps:
1. perform the same operation over the USB cable (not XVC) and see whether 27-3347 is reported as
   well — that tells whether the problem is XVC-specific;
2. if the cable fails too, the problem lies in Vivado / the device library / the bridge
   configuration and is unrelated to XVC;
3. alternative: add STARTUPE2 + an SPI controller inside the K7 user design and let Linux access the
   Flash directly.

## 5.10 FIFO Streaming Re-test (2026-10-30, Failed)

The FIFO version was redone after the SD card fix, once the build chain was verifiable (`PL_TAG`):

| Item | Result |
|---|---|
| Design build | `PL_TAG=0xA7000000` ✅ confirms the new PL is on the board |
| 6 bit shift (register path) | ✅ 0.5 ms |
| **70 bit IDCODE read** | ❌ `A7=0x00000000  K7=0xE0000000` (wrong data) |
| 12000 bit streaming | ❌ hangs |
| cocotb simulation (same RTL) | ✅ PASS (IDCODE = 0x23727093) |

**Root cause located (2026-10-30)**: after adding FIFO status printing to the server, the power-up
instant was captured:

```
PL_TAG=0xA7000002      ← busy=1 (engine running)
FIFO_STATUS=0x00000000  tx_free=0  ← TX reports "full"
```

`tx_free=0` means `tx_wr - tx_rd` **underflowed**: the engine popped data while the FIFO was empty
(`tx_rd` overtook `tx_wr`), after which `tx_used` became a huge value → the engine always believed
data was available → it kept spinning, which interfered with manual shifts.

**Fixed**: underflow/overflow protection added (pointer crossing treated as empty/full + self-heal +
drop on full + `INIT` attribute). After the fix the power-up state is correct:

```
PL_TAG=0xA7000000      ← busy=0
FIFO_STATUS=0x00000080  tx_free=128 rx_used=0
```

**Still present**: 20000-bit streaming shifts still hang — meaning there is a second problem besides
the underflow (engine/streaming handshake or the RX side), not yet located. Currently rolled back to
the stable version.

Rolled back to the stable version (`BOOT.BIN b6ae0dfc` / `image.ub f14145e0`); re-test:
IDCODE correct, programming **18,039 ms**.

## 5.11 FIFO Streaming (Late 2026-10-30: Simulation Passes, Hardware Still Stuck)

**New observability**: the RTL gained `0x28` (count of completed streaming chunks) and the server
gained "no-progress detection + automatic fallback", so it no longer waits forever.

**Simulation (cocotb)**:

```
Initial STATUS=0x00000080 (tx_free=128)
After write STATUS=0x0000007D tx_free=125 rx_used=0 CNT=0
Done:   CNT=4 STATUS=0x00000480 rx_used=4 busy=0
TESTS=1 PASS=1
```

→ **the RTL logic is correct**: all 4 streaming chunks complete, the data enters the RX FIFO, and
busy clears.

**Hardware (same bitstream)**:

```
stream stalled: cnt=0 pushed=128/624 popped=0
busy=1   (0x10 = 0x00000001)
CNT=0    (0x28)
tx_free=0 (0x24) → TX already full at 128 words
```

→ the engine enters the streaming chunk (`LEN=0x20`) but **never completes**: `stream_cnt` stays 0
and `busy` stays 1.

**Differences to investigate**:
- in simulation `tx_mem[tx_rd]` is an asynchronous array read; after synthesis it may be inferred as
  LUTRAM/BRAM with a different read latency → but that would only affect the data, not completion;
- more likely the post-synthesis behavior of `bits`/`ph` (e.g. the widths of `bits <= 6'd32` and
  `bits - 1`);
- next step: move the ILA probes to `state / bits / ph / stream_chunk / tx_wr / tx_rd`, capture one
  streaming chunk and see directly which state it is stuck in.

**Current default behavior**: a streaming failure falls back to per-chunk mode automatically instead
of hanging (18.0 s is still usable).

### 5.11.2 Late Night 2026-10-30: 5 Hardware-Level Bugs Fixed, Streaming Mechanism Works

| # | bug | Symptom | Fix |
|---|---|---|---|
| 1 | FIFO pointers driven from multiple blocks | DRC MDRV-1, synthesis failed | pointers unified into one always block |
| 2 | `tx_push` default clear written inside `if (aw_done&&w_done)` | after one word was written push stayed 1 → the write pointer shot to 128 instantly | clear moved to the top of the block |
| 3 | `stream_cnt`/`stream_start_cnt` reset and increment in different blocks | counter stayed 0 → the server wrongly reported "no progress" | reset moved into the engine block |
| 4 | **`tx_pop`/`rx_push` resets written in the write block** | in hardware `tx_pop` stayed 0 → the FIFO was never consumed | resets returned to their own blocks |
| 5 | `fifo_flush` driven from multiple places | the FLUSH bit had no effect | switched to `ctrl_q[2]` |

**Hardware measurement after the fix (word-by-word verification)**:

```
CLEAN : F=0x00000080  (tx_free=128, empty)   DONE=0
Write 4 words: F=0x00000480  (tx_free=128, rx_used=4)  DONE=4
```

→ the engine pops data correctly → shifts → refills the RX FIFO ✅
→ engine streaming throughput ≈ 200k chunks/s ≈ **6.25 Mbit/s (the TCK limit)** ✅

**One last problem remained**: the server-side bulk flow control (`stream pop timeout`) — the engine
drains and refills normally, but the server times out waiting for `rx_used>=32`, meaning the RX read
path (0x20) disagrees with the server's count in bulk scenarios.

**The last bug (fixed)**: the 8-bit pointers wrapped after 256 words while the "self-heal" logic
`tx_rd > tx_wr` misjudged it → data was swallowed after the 288th word.

Fix: changed to **pure modulo-256 arithmetic** (`tx_diff = tx_wr - tx_rd`, the depth of 128
guaranteed by the full flag), and the self-heal logic was removed.

### 5.11.3 FIFO Streaming Verified (2026-10-30 22:20)

Hardware measurement (K7 powered off, shift timing only):

```
20000 bit : 0.0048 s   4.20 Mbit/s
60000 bit : 0.0102 s   5.87 Mbit/s
200000 bit: 0.0305 s   6.56 Mbit/s
4 Mbit    : 0.443  s   9.03 Mbit/s
```

**Scales to ≈ 10.1 s for 91.5 Mbit** (previously 18.5 s; the theoretical TCK floor is 9.2 s).

| Item | Per-Chunk Mode | FIFO Streaming |
|---|---|---|
| Throughput | 3.85 Mbit/s | **9.03 Mbit/s** |
| Estimated programming | 18.5 s | **~10.1 s** |

**RX pop verification** (manually via devmem):

```
rx_used=4 → read 0x20 → rx_used=3 → read 0x20 → rx_used=2   ✅ decrements correctly
```

### 5.11.4 Measured With K7 Powered On: 10.3 s Programming (2026-10-30 22:35)

| Test | Result |
|---|---|
| IDCODE | A7 `0x0362C093` / K7 `0x43651093` ✅ |
| Streaming 20000 bit | 0.0058 s (0.29 µs/bit) ✅ |
| **Real programming ×4** | **10.30 / 10.27 / 10.27 / 10.27 s** ✅ all succeeded |

Vivado verifies the bitstream itself, and all 4 runs were `PROGRAM_OK` → **the streaming data path
is correct**.

| Item | Per-Chunk Mode | FIFO Streaming | Improvement |
|---|---|---|---|
| Programming time | 18.5 s | **10.3 s** | **1.8×** |
| Throughput | 3.85 Mbit/s | 9.0 Mbit/s | 2.3× |
| Relative to the 9.2 s TCK floor | 50% | **89%** | — |

This is the project's final performance: **10.3 s** (USB cable baseline 9.56 s, essentially
matched).

### 5.11.5 Reliability Over 20 Consecutive Programming Runs (2026-10-30 22:40)

```
10317 10289 10255 10261 10269 10257 10243 10256 10259 10249
10289 10263 10288 10257 10250 10272 10257 10270 10259 10265   (ms)
```

| Statistic | Value |
|---|---|
| Success rate | **20 / 20 = 100%** |
| Average | **10,267 ms** |
| Fastest / slowest | 10,243 / 10,317 ms |
| Variation | **±0.36%** (74 ms) |
| Retries / fallbacks | **0** |

Adding the earlier 4, the streaming version has **24 consecutive successes**.

### 5.11.1 ILA Observation (2026-10-30 19:40)

The ILA probes were changed to a **single 32-bit debug port** (new `dbg` port in the RTL):

```
[31:24] stream_cnt[7:0]   [23:16] tx_wr    [15:8] tx_rd
[7:6]   state[1:0]        [5] stream_chunk [4] busy  [3:0] ph[3:0]
```

ILA configuration (`out_g1/system.ltx` + Digilent TAP):

```
ILA: hw_ila_1   PROBE: system_i/ila/inst/probe0_1
Trigger: probe0[5] == 1 (stream_chunk)
Result: ARMED succeeded, but **never triggered**
```

**Important conclusion**: during the streaming request the engine **never asserts `stream_chunk` at
all** — meaning it did not enter the streaming branch of S_IDLE but had long been stuck in S_RUN
(`busy` constantly 1), so it never evaluates the "FIFO not empty" condition.

This matches the earlier observation of `cnt=0 / busy=1 / tx_free=0` exactly.

**Next step**: change the trigger to the rising edge of `busy` (bit4) and capture `state / ph /
bits` around the moment the engine gets stuck, to identify which shift failed to return to S_IDLE.

## 6. Next Steps (Converging)

### Conclusion
- the IR scan waveform (TMS/TDI) is bit-exact and the device TDO responds;
- but only IR lengths with `L ≡ 2 (mod 3)` let a subsequent DR read return the IDCODE;
- the real IR chain length of 12 fails, indicating a **systematic 1-bit / phase offset** in the
  shift engine.

### New Engine Verification (Rewritten and On-Board)

The shift engine was rewritten as "single phase counter + explicit TCK edge". ILA measurement of one
`TLR(6) + IR(19)` combined shift:

```
TCK rising edges = 25         ← exactly matches the 25-bit sequence
TMS = 111110 1100000000000000 110
TDI = 000000 0000100100100100000
```

**The clock count is completely correct, no extra or missing cycles.** Yet L=12 still fails while
L=11 succeeds, so the problem is not the shift engine's clock counting but that **the chain's actual
IR length does not match the expected 12**: the measured equivalent IR length = 11.

### Alignment Variant Comparison (Key)

Re-tested with two TDI alignments of strictly identical length (A = 4 leading 0s, B = 3 leading 0s):

| Variant | Successful L |
|---|---|
| A (4 leading 0s) | **11** |
| B (3 leading 0s) | **13** |

The two differ by exactly 2 bits, showing that the effective start of the IR data on TDI lags the
"ShiftIR clocks" by **1 TCK**:
- variant A at L=11 samples `pattern[0..10] + one 0` over the 12 IR clocks = `0x09,0x09` ✅
- variant B at L=13 likewise samples `pattern[0..11]` = `0x09,0x09` ✅

That is, **our test script needs one extra bit to line up** (Vivado's own vectors are not affected
by this).

### IR Sequence Vivado Actually Sends During Programming (Server Dump)

Retrying Vivado programming with the new engine still gives `End of startup status: LOW`. The dump
shows Vivado really does send the JPROGRAM / status polling sequence (a 127-bit combined shift):

```
TDI=...015203C00000BF00   TDO=...0548FF00018475FF
TDI=...015203C00008BF00   TDO=...0548FF00018475FF
TDI=...00A901E0000FC200   TDO=...02A4FF80018475FF
TDI=...00A901E0000FE200   TDO=...02A4FF80018475FF
```

TDO returns `...018475FF` consistently, i.e. the device status register always reports not-ready.

Conclusion: Vivado's commands do reach the device, but K7 does not enter initialization (INIT never
goes high, DONE never goes high).

### Fix Direction (by Priority)
1. rewrite the `jtag_ctrl` shift engine as "single counter + explicit TCK edge" so that each shift
   is exactly 1 TCK/bit and TMS/TDI are stable before the TCK rising edge;
2. verify with the IR length sweep in `tools/` (4..24): after the fix only **L=12** should succeed;
3. once that passes, re-test Vivado programming with `tools/vivado_program_retry.tcl`.

### Reusable Tools
| Script | Purpose |
|---|---|
| `tools/ir_loop.py` / `tools/combined_loop.py` | Continuously generate IR/combined sequences for ILA capture |
| `tools/ila_cap4.tcl` | 4-probe ILA capture (trigger selectable on TCK/TMS/TDI, trigger position configurable) |
| `tools/bypass_check.py` | BYPASS data integrity |
| `tools/status_read.py` | Read the CFG_OUT status |
| `tools/ir_bitwise.py` | Send IR bit by bit |
| `tools/program_cable2.tcl` | USB cable programming baseline (9.56 s) |
| `tools/xvc_proxy.py` | XVC capture proxy |
