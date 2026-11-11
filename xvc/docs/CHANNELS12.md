# 12-Channel Parallel XVC

> 2026-10-31
> Goal: 12 XVC channels **truly parallel** (each with its own engine, no blocking between them)

## Ports and Addresses

| Port | Channel | AXI Address | Pin Group |
|---|---|---|---|
| **2542** | Broadcast | — | Applies to the 12 channels in sequence |
| **2543** | ch0 | `0x43C00000` | G1: J20 pin3-6 (R14/P14/U12/T12) |
| **2544** | ch1 | `0x43C10000` | G2 |
| **2545** | ch2 | `0x43C20000` | G3 |
| ... | ... | ... | ... |
| **2554** | ch11 | `0x43CB0000` | G12 |

Each channel has a **64 KB** address space, 768 KB in total.

## Architecture

```
                    ┌── jtag_ctrl #0 ── G1  (0x43C00000)
                    ├── jtag_ctrl #1 ── G2  (0x43C10000)
PS M_AXI_GP0 ── axi_interconnect(1×12)
                    ├── ...
                    └── jtag_ctrl #11 ─ G12 (0x43CB0000)
```

**12 fully independent jtag_ctrl engines**, each with its own FIFO streaming channel, its own
TCK divider, and its own shift state machine — they do not affect each other and can work concurrently.

## Resource Utilization

| Resource | Used | Utilization |
|---|---|---|
| Slice LUTs | 3,263 | **6.13%** |
| Slice Registers | 2,088 | 1.96% |
| Bonded IOB | 37 | 29.6% |
| Block RAM | 0 | 0% |

## Measured Results

### Independence Verification (Key)

```
Write DIV: ch0=5, ch1=9, ch2=3, ch11=7
Read back: C0=5, C1=9, C2=3, C11=7   ✅ Fully isolated
```

### Parallel Scan

All 12 ports scanned simultaneously (completed in 0.03 s):

```
ch0 : A7=0x0362C093 K7=0x43651093   ← real chain
ch1~ch11: 0xFFFFFFFF                ← no device attached (TDO pulled up)
```

### Parallel Throughput

200,000 bits shifted simultaneously on each of the 12 channels:

| Metric | Value |
|---|---|
| Total wall-clock time | **0.291 s** |
| Average per channel | 0.150 s |
| Serial theoretical value | 1.80 s |
| **Speedup** | **6.2×** |

(Less than 12× because the PS AXI master port and DDR bandwidth are shared)

### Programming Speed

| Item | Result |
|---|---|
| ch0 programming | **10.33 s** (2/2) |
| vs. single-channel version | No difference ✅ |

## Build

```bash
vivado -mode batch -source xvc/vivado/build_jtag12p.tcl
# Output: xvc/vivado/work_jtag12p/jtag12p.runs/impl_1/system_wrapper.bit
```

**Note**: the script does not copy the result to out_dir automatically; use cp manually.

## Server

```bash
/tmp/xv12p -a 0x43C00000 -d 5
```

Each connection maps its own address window as `base + ch*0x10000`;
each child process mmaps independently ✓ no global lock contention.

## Pitfalls Encountered

1. **Address mapping**: `assign_bd_address` only auto-assigned the first one;
   you must assign them one by one with
   `assign_bd_address -offset <addr> -range 64K -target_address_space /ps7/Data`;
2. **Bitstream file**: the build output lands in `work_*/…/impl_1/`, and `out_dir` must be
   copied manually — otherwise the old bitstream is programmed (symptom: "all channels read
   back the same engine");
3. **settck speed reduction**: the server has been locked to the TCK given by `-d` and ignores
   client requests;
4. **TDO multiplexing** (leftover issue from the mux version): the single-engine approach is
   unusable; it has been changed to multiple engines.

## Broadcast TDO Select Register

The broadcast port (2542) applies one and the same shift to the 12 channels in sequence;
**which channel's TDO is returned is selected by register `0x43C0003C`**:

| Register | Meaning |
|---|---|
| `0` (default, reset value) | Returns the TDO of **G1 (ch0)** |
| `1` | Returns the TDO of ch1 |
| ... | ... |
| `11` | Returns the TDO of ch11 |

```bash
# Default: return G1's real chain
devmem 0x43C0003C 32 0
#   -> broadcast scan gives A7=0x0362C093 K7=0x43651093

# Change to returning ch1 (empty chain)
devmem 0x43C0003C 32 1
#   -> broadcast scan gives A7=0xFFFFFFFF K7=0xFFFFFFFF
```

The register is in **ch0's address window** (`0x43C00000 + 0x3C`). In the 12-engine version
it was originally used for channel selection in the mux scheme; it is now dedicated to
broadcast TDO selection.

Measured:

| Setting | Broadcast Return |
|---|---|
| `0` (default) | `A7=0x0362C093 K7=0x43651093` ✅ real chain |
| `1` | `A7=0xFFFFFFFF K7=0xFFFFFFFF` ✅ empty chain |

## Known Issues

- ch1~ch11 have not yet been validated against a real target board
