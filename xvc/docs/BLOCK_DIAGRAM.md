# XJSM-P12-Z7000 System Block Diagram

> 2026-11-02 · corresponds to `block_diagram.svg`

## 1. Overall Architecture

```
┌──────────────┐   Ethernet     ┌────────────────────────────┐
│   Host PC    │  2542/2543-54  │      Zynq PS (Linux)       │
│  Vivado      │ ─────────────► │  xvcserver_g1 + xvcweb     │
│  192.168.1.50│                │      eth0 192.168.1.113    │
└──────────────┘                └─────────────┬──────────────┘
                                              │ AXI GP0 @ 0x43C00000
                                              ▼
                              ┌───────────────────────────────────┐
                              │   PL — 12 × jtag_ctrl engines     │
                              │                                   │
                              │  ch0  ch1  ch2  ch3               │
                              │  ch4  ch5  ch6  ch7               │
                              │  ch8  ch9  ch10 ch11              │
                              │                                   │
                              │  Each: 0x43C00000 + ch×0x10000    │
                              └───────────────┬───────────────────┘
                                              │
                         TCK/TMS/TDI shared ──┤── TDO separate ×12
                                              ▼
                              ┌───────────────────────────────────┐
                              │  J20 / J21 expansion (48 pin)     │
                              │   jtag1_* … jtag12_*              │
                              └───────────────┬───────────────────┘
                                              │
                                              ▼
                              ┌───────────────────────────────────┐
                              │   External JTAG chain             │
                              │   AMD Xilinx FPGA chain            │
                              └───────────────────────────────────┘
```

## 2. Register Map (Per Engine)

| Offset | Name | Description |
|---|---|---|
| `0x00` | LEN | Bit length |
| `0x04` | TMS | TMS data |
| `0x08` | TDI | TDI data |
| `0x0C` | TDO | TDO readout |
| `0x10` | CTRL | bit0=start, bit1=release, bit2=clear FIFO |
| `0x14` | DIV | Clock divider (write); `PL_TAG` readout = `0xA7xxxxxx` |
| `0x18` | DIV_RB | Divider readback |
| `0x1C` | TXD | TX FIFO data |
| `0x20` | RXD | RX FIFO data |
| `0x24` | STATUS | `{0, rx_used, tx_free}` |
| `0x28` | DONE | Completion flag |
| `0x2C` | PH | Phase |
| `0x30` | STATE | State machine |
| `0x34` | START | Start count |
| `0x38` | SEQ | Sequence number |
| `0x3C` | CHSEL | Broadcast TDO source ✅ available |
| `0x40` | BCMASK | Broadcast mask ❌ not implemented in the bitstream |

## 3. Broadcast Path (Key Design)

### Hardware Topology

```
        ┌─────────┐
        │ ch0     │──TCK──┐
        │ engine  │──TMS──┤
        │         │──TDI──┤
        └─────────┘       │      ┌──────────────┐
        ┌─────────┐       ├─────►│  J20/J21     │──► AMD Xilinx
        │ ch1     │──TCK──┤      │  12 channels │──► AMD Xilinx
        │ engine  │──TMS──┤      │  TCK/TMS/TDI │
        │         │──TDI──┤      │  ext-shorted │
        └─────────┘       │      └──────────────┘
        ...               │
        ┌─────────┐       │
        │ ch11    │──TCK──┤
        │ engine  │──TMS──┤
        │         │──TDI──┘
        └─────────┘

        TDO: 12 separate ──► MUX ──► ch0's TDO input
                              ▲
                          CHSEL (0x3C)
```

### Conclusion

**Driving a single engine (ch0) is enough to affect all 12 connectors** ✅

because TCK/TMS/TDI are the same wires ✓ all 12 devices receive the same waveform at the same time ✓

### Server Implementation

```c
static int do_shift(int nbits, const uint8_t *tms, const uint8_t *tdi, uint8_t *tdo)
{
    int sel;
    if (!g_bcast) return do_shift_one(nbits, tms, tdi, tdo);

    if (map_channel(g_base, 0) < 0) return -1;
    sel = (int)(rd(REG_CHSEL) & 0xF);
    if (sel >= XVC_NCH) sel = 0;
    wr(REG_CHSEL, (uint32_t)sel);          /* TDO source */
    wr(0x14, g_min_div);
    return do_shift_one(nbits, tms, tdi, tdo);   /* run only once */
}
```

| Implementation | Time | Waveform |
|---|---|---|
| Old: 12 × `do_shift_one` | 12 × T ✗ | overwrite each other ✗ |
| **New: 1 call + CHSEL** | **T** ✅ | synchronized ✓ |

## 4. Port Assignment

| Port | Purpose |
|---|---|
| 80 | Web console (httpd + CGI) |
| 2542 | XVC broadcast (all 12 connectors) |
| 2543 ~ 2554 | XVC channels 0 ~ 11 |

## 5. Performance

| Item | Value |
|---|---|
| Single-channel programming | 10.27 s / 91.5 Mbit (20/20, ±0.36%) |
| Broadcast programming | serial 12× ✗ → single engine T ✅ (source changed, pending build) |
| TCK | 10 MHz (DIV=5, 100 MHz / (2×5)) |
| Flash programming (with verify) | 200.7 s |

## 6. Files

| File | Description |
|---|---|
| `block_diagram.svg` | Visual block diagram (open in a browser ✓) |
| `BLOCK_DIAGRAM.md` | This document (ASCII version ✓) |


---

# 7. Broadcast Priority (2026-11-02 Final Strategy)

## Rules

**Broadcast first (top priority)** — when a broadcast client connects, existing single-channel XVC connections on the selected channels are **disconnected automatically**.

## Implementation

The server `fork()`s one process per client. On startup the broadcast child process runs:

```c
if (g_bcast) kill_other_clients();   /* broadcast first: kick the single-channel connections */
```

`kill_other_clients()` scans `/proc/*/cmdline`, finds all `xvcserver_g1` processes,
skips the **parent process** (the listener) and **itself**, and sends `SIGTERM` then `SIGKILL`:

```c
static pid_t g_parent_pid = 0;   /* recorded before fork */

for each /proc/<pid>/cmdline:
    if (pid == self || pid == g_parent_pid) continue;
    if (strstr(cmdline, "xvcserver_g1")) kill(pid, SIGTERM);
usleep(300000);
... then another SIGKILL round ...
```

## Verification Result

```
ch3 connect:       xvcServer_v1.0:4194304   ✓
broadcast connect: xvcServer_v1.0:4194304   ✓
ch3 state:         disconnected (EOF)       ✓✓✓
```

## Three Scenarios

| Scenario | Behavior |
|---|---|
| Single-channel connection running alone | normal ✓ |
| Broadcast connects (channels selected) | the single-channel connections on those channels are **disconnected** ✓ broadcast takes over ✓ |
| Broadcast disconnects | each channel returns to independent operation ✓ (`bcast_en` cleared) |

## Hardware Arbitration Cooperation

```verilog
wire follow = bcast_en & mask_eff[i];
assign pin_tck[i] = follow ? bc_tck : ch_tck[i];
```

Software disconnects the connection + hardware mux switching, a double safeguard ✓


---

# 8. Updated Block Diagram (2026-11-02, Broadcast + 12-Engine Final Version)

## 8.1 System Block Diagram

See `system_block.svg` (open in a browser). Structure:

```
┌──────────────┐  Ethernet          ┌──────────────────────────┐
│  Host PC     │  2542 / 2543-2554  │  Zynq PS                 │
│  Vivado      │ ─────────────────► │  xvcserver_g1            │
│ 192.168.1.50 │                    │  fork() one per client   │
└──────────────┘                    │  bcast-prio kill_other   │
                                    │  xvcweb :80              │
                                    └───────────┬──────────────┘
                                                │ AXI GP0
                                                ▼
                          ┌──────────────────────────────────────────┐
                          │ PL — axi_interconnect NUM_MI = 13        │
                          │                                          │
                          │  jtag0..11   0x43C00000 + ch*0x10000     │
                          │       │ tck/tms/tdi/tdo independent      │
                          │       ▼                                  │
                          │  ┌──────────────────────────────┐        │
                          │  │ jtag_bcast_mux               │        │
                          │  │ follow[i] = bcast_en & mask  │        │
                          │  └──────────────┬───────────────┘        │
                          │                 │                        │
                          │  jtag12  0x43CC0000  ★ broadcast engine  │
                          │       (bc_tck/bc_tms/bc_tdi)             │
                          └─────────────────┬────────────────────────┘
                                            │ 48 pin
                                            ▼
                          ┌──────────────────────────────────────────┐
                          │ J20 / J21                                │
                          │ TCK/TMS/TDI shorted · TDO separate ×12   │
                          └─────────────────┬────────────────────────┘
                                            ▼
                          ┌──────────────────────────────────────────┐
                          │ AMD Xilinx FPGA chain                     │
                          └──────────────────────────────────────────┘
```

## 8.2 RTL Block Diagram

See `rtl_block.svg`. Core modules:

| Module | Instances | Function |
|---|---|---|
| `jtag_ctrl` | **13** | TAP engine (12 channels + 1 broadcast) |
| `jtag_bcast_mux` | 1 | Per-channel TCK/TMS/TDI 2:1 select |
| `xlconcat` | 4 | Merges 12 tck/tms/tdi/tdo into a bus |
| `xlslice` | 36 | 12 groups × 3 signal slice outputs |
| `axi_interconnect` | 1 | NUM_MI=13, 64 KB per slave |

### Inside jtag_ctrl

```
AXI-Lite slave → register file → TX FIFO(128×32) → TAP state machine → RX FIFO(128×32)
                                                      │
                                                      ▼
                                             tck / tms / tdi / tdo
```

### Clock and Streaming

```
TCK = 100 MHz / (2 × DIV)      DIV=5 → 10 MHz
Streaming: write TXD(0x1C) → hardware shifts in 32-bit chunks → read RXD(0x20)
STATUS(0x24) = {16'd0, rx_used, tx_free}
SEQ(0x38) = {go_seq, seen_seq} — equality means the shift is complete
```

## 8.3 Two Files

| File | Content |
|---|---|
| `system_block.svg` | System level (PC → PS → PL → target board) |
| `rtl_block.svg` | RTL level (broadcast + 12 engines + mux + register map + internal structure) |

---

# 9. Clean Architecture Refactor (2026-11-02 Final Version)

## 9.1 Design Principles

**13 identical jtag_ctrl + 1 standalone register block + 1 repeater**

Broadcast control is no longer crammed inside jtag_ctrl.

## 9.2 Three Modules

| Module | Instances | Description |
|---|---|---|
| **`jtag_ctrl.v`** | **13** | Identical TAP engines (**zero changes**) |
| **`jtag_bcast_regs.v`** | 1 | Standalone AXI-Lite register block |
| **`jtag_repeater.v`** | 1 | Pure combinational arbitration (per-channel 2:1 select + 12:1 TDO select) |

## 9.3 Address Map

```
0x43C00000 + ch*0x10000   ch0..ch11 (12 channel engines)
0x43CC0000                broadcast engine (the 13th jtag_ctrl)
0x43CD0000                broadcast control register block
```

## 9.4 Register Block (0x43CD0000, TAG = 0xB7000000)

| Offset | Name | Description |
|---|---|---|
| `0x00` | CTRL | bit0 = bcast_en |
| `0x04` | BCMASK | [11:0] channels participating in broadcast (default 0xFFF) |
| `0x08` | CHSEL | [3:0] which TDO is read back during broadcast |
| `0x0C` | TAG | read-only `0xB7000000` |
| `0x10` | STATUS | [11:0] effective mask (all selected when 0) |

### Address Decoding Uses `==` Comparison, Not `case`

```verilog
if (waddr_q[7:2] == 6'd0)      bcast_en <= wdata_q[0];
else if (waddr_q[7:2] == 6'd1) bcmask   <= wdata_q[11:0];
else if (waddr_q[7:2] == 6'd2) chsel    <= wdata_q[3:0];
```

**The old design used `case (waddr[7:2])`, so the 0x40 address could not be written** (synthesis issue).
The new design uses equality comparison, and **all registers behave correctly**.

## 9.5 Repeater Logic

```verilog
for (i = 0; i < 12; i++) begin
    wire follow = bcast_en & bcmask_eff[i];
    assign pin_tck[i] = follow ? bc_tck : ch_tck[i];
    assign pin_tms[i] = follow ? bc_tms : ch_tms[i];
    assign pin_tdi[i] = follow ? bc_tdi : ch_tdi[i];
end
assign bc_tdo = (chsel < 12) ? ch_tdo[chsel] : 1'b0;
```

Purely combinational, no registers, no timing-path problems.

## 9.6 Verification Result

```
ch0  TAG  : 0xA7000000   ✓ channel engine
bc   TAG  : 0xA7000000   ✓ broadcast engine (same module)
regs TAG  : 0xB7000000   ✓ register block
regs CTRL : 0x00000000   ✓
regs MASK : 0x00000FFF   ✓ all selected by default
regs SEL  : 0x00000007   ✓

Write CTRL=1     → read 0x00000001  ✓
Write MASK=0xABC → read 0x00000ABC  ✓✓  (the old inability to write 0x40 is gone)
Write SEL=7      → read 0x00000007  ✓

Broadcast priority: ch3 connects → broadcast connects → ch3 receives EOF ✓
```

## 9.7 Comparison With the Old Version

| Item | Old version (control embedded in each of the 13 engines) | New version (three-stage) |
|---|---|---|
| `jtag_ctrl.v` | 3 ports added ✗ | **zero changes** ✓ |
| Control registers | crammed into CTRL[27:16] of ch12 ✗ | **standalone block** ✓ |
| 0x40 not writable | had this problem ✗ | **solved with == comparison** ✓ |
| Readability | poor ✗ | good ✓ |
| Verification result | partly abnormal ✗ | **all normal** ✅ |

---

# 10. Broadcast Session and Session Management (2026-11-03 Final)

## 10.1 Six Design Decisions

| Q | Question | Decision |
|---|---|---|
| Q1 | kill scope | **B** per-channel pid file, kill only those inside the mask |
| Q2 | Client behavior after broadcast | accept it, reconnect manually |
| Q3 | Connecting during S_BC | **B** fail fast (`state==3` → return -1) |
| Q4 | CHSEL outside the mask | **B** auto-correct to the lowest number inside the mask |
| Q5 | Server startup | **A** clear `bcast_en=0` |
| Q6 | Empty mask | **C** UI forbids deselecting everything |

## 10.2 Handling of Four Special Cases

| # | Problem | Solution |
|---|---|---|
| **N1** | Two clients on the same channel | pid file + `proc_is_xvcsrv()` → REFUSE |
| **N2** | Two broadcast clients | 2542 also has a pid file → REFUSE |
| **N3** | pid reuse kills the wrong process | verify `/proc/<pid>/comm` |
| **N4** | Leftover state after a broadcast crash | **C** self-heal on accept |

## 10.3 Session Lifecycle

```
Broadcast client connects to 2542:
  ① write /tmp/xvcsrv-2542.pid   ← first prove "I am here"
  ② wr(CTRL, 1)                  ← then close the gate
  ③ read pids in mask → kill     ← kill only the affected channels
  ④ handle_client() (whole session)
  ⑤ wr(CTRL, 0) + delete pid file

Channel port accept:
  ① heal_bcast_if_stale()        ← self-heal
  ② port_has_session(port)? → REFUSE
  ③ bcast_en && mask[ch]? → REFUSE
  ④ fork → write pid → handle_client → delete pid
```

## 10.4 pid Files

```
/tmp/xvcsrv-2542.pid   broadcast
/tmp/xvcsrv-2543.pid   ch0
...
/tmp/xvcsrv-2554.pid   ch11
```

`/proc/<pid>/comm` must contain `xvcserver_g1` for a session to count as valid ✓ prevents pid-reuse mix-ups ✓

## 10.5 Self-heal Function

```c
static void heal_bcast_if_stale(void)
{
    if (!(rd(CTRL) & 1)) return;                 /* broadcast not enabled */
    int pid = read_pid_file(2542);
    if (pid > 0 && proc_is_xvcsrv(pid)) return;   /* the session really exists */
    wr(CTRL, 0);                                  /* leftover → clear it */
    unlink_pid_file(2542);
    fprintf(stderr, "self-heal: stale bcast_en cleared\n");
}
```

**Called on every accept** ✓ all 13 ports are treated the same ✓

## 10.6 Measured Results

```
Single port, single session:
  1st connection: xvcServer_v1.0:4194304   ✓
  2nd connection: refused ✓
  reconnect after close: restored ✓

Broadcast exclusive (mask 0xFFF):
  broadcast session established ✓
  12 channel ports: 12/12 refused ✓
  after the broadcast closes: 12/12 restored   ✓

Self-heal:
  devmem manually sets bcast_en=1 (no session)
  → the next accept clears it automatically ✓
```

## 10.7 Supporting RTL

```
S_RUN + bcast_sel → wait for ph_end (complete TCK falling edge) → S_BC
S_IDLE + bcast_sel → S_BC
S_BC + !bcast_sel → S_IDLE

S_BC actions: tck/tms/tdi=0, running=0, tdo_q=0,
              fifo_clr=1, seen_seq←go_seq
```

State encoding: `S_IDLE=0, S_RUN=1, S_BC=3` (read `0x30[3:2]`)

---

# 11. Timing Constraints and Quality Metrics (2026-11-03 Final)

## 11.1 Complete Constraints in jtag12.xdc

In addition to the 48 `PACKAGE_PIN` + `IOSTANDARD` + pull-up/pull-down constraints, two classes of timing constraints were added:

```tcl
# TDO inputs (12 groups)
set_input_delay -clock clk_fpga_0 -max 5.000 [get_ports {jtag*_tdo}]
set_input_delay -clock clk_fpga_0 -min 1.000 [get_ports {jtag*_tdo}]

# TCK/TMS/TDI outputs (36 groups)
set_output_delay -clock clk_fpga_0 -max 5.000 [get_ports {jtag*_tck jtag*_tms jtag*_tdi}]
set_output_delay -clock clk_fpga_0 -min 1.000 [get_ports {jtag*_tck jtag*_tms jtag*_tdi}]

# each bit spans 2*DIV = 10 clk_fpga_0 periods
set_multicycle_path 10 -setup -to [get_ports {jtag*_tck jtag*_tms jtag*_tdi}]
set_multicycle_path  9 -hold  -to [get_ports {jtag*_tck jtag*_tms jtag*_tdi}]
```

### Why a multicycle Path Is Needed

```
clk_fpga_0       = 100 MHz (10 ns)
JTAG output path = FF → mux → slice → OBUF ≈ 10.75 ns (exceeds a single cycle)
Actual data rate = 100 MHz / (2×DIV) = 10 MHz (100 ns/bit)
```

Single-cycle analysis reports `TIMING-16` (WNS -5.747 ns); it must be analyzed as 10 cycles.

## 11.2 Fix Process (Four Steps)

| Stage | Methodology Violations | WNS |
|---|---|---|
| Initial | 48 × TIMING-18 | +1.337 ns |
| Only `set_input_delay` added | 36 (TDO fixed) | +1.298 ns |
| `set_output_delay -max 5` added | **36 × TIMING-16** | **-5.747 ns** ❌ |
| **`set_multicycle_path 10` added** | **0** | **+0.307 ns** ✅ |

## 11.3 Final Quality Metrics

| Metric | Value |
|---|---|
| WNS | **+0.307 ns** |
| WHS | +0.048 ns |
| WPWS | +3.870 ns |
| Failing endpoints | **0 / 39,622** |
| Methodology violations | **0** |
| Slice LUTs | 9,057 / 53,200 (**17.02%**) |
| Slice Registers | 7,589 / 106,400 (**7.13%**) |
| Block RAM | 0 / 140 |
| DSP | 0 / 220 |
| Bonded IOB | 48 / 125 (**38.4%**) |
| BUFGCTRL | 1 / 32 |

### LUT Breakdown

| Purpose | Count |
|---|---|
| LUT as Logic | 6,707 (12.61%) |
| LUT as Memory (distributed RAM, used for the FIFOs) | 2,350 (13.51%) |

The FIFOs of all 13 engines (12 channels + 1 broadcast, 128×32 bit each) use distributed RAM rather than BRAM;
they could be moved to 26 RAMB18s to free 2,350 LUTs, but the current margin is ample, so
no optimization is needed.

## 11.4 RTL Lint

| Rule | Count | Source |
|---|---|---|
| ASSIGN-10 | 58 | `system.v` (IPI generated) |
| ASSIGN-5 | 21 | `system.v` (PS7 DDR unused) |
| **Hand-written RTL** | **0** | jtag_ctrl / repeater / bcast_regs |

All 79 come from Vivado auto-generated code; creating waivers is recommended.

## 11.5 Artifact Versions

| Artifact | md5 |
|---|---|
| BOOT.BIN | `835b4152` |
| image.ub | `d8685f59` |
| Bitstream | `7272de42` |
| Server | `d6728f30` |
| xvcinfo | `55a4b777` |
