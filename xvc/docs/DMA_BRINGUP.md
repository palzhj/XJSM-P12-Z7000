# DMA bring-up log

Status: **the stall was a real RTL bug in the FIFO handshake, not a DMA or a
block-design problem — see "Root cause" at the end. Fixed and verified in
simulation; the bitstream is rebuilt and the on-board re-measurement is the only
thing left.**
Last updated 2026-11-12 (second pass).

> This document records the reasoning as it happened, including two hypotheses
> that turned out to be wrong. For the current state and the next step see
> [`SESSION_HANDOFF.md`](SESSION_HANDOFF.md).

## Correction: DMACR bit1 is not Reset

The IP's own VHDL settles it:

```vhdl
constant DMACR_RS_BIT      : integer := 0;
constant DMACR_TAILPEN_BIT : integer := 1;   -- Tail descriptor pointer enable
constant DMACR_RESET_BIT   : integer := 2;   -- Reset is bit 2, not bit 1
```

So `MM2S_DMACR = 0x00010003` is a **normal running configuration**, not a stuck
reset. The driver writes `4` (bit 2) for reset, which is correct. An earlier
section of this log blamed a stuck Reset bit; that was wrong.

## What is in place

| Layer | State |
|---|---|
| `jtag_ctrl.v` | AXI-Stream ports `s_axis_tdi_*` / `m_axis_tdo_*` / `m_axis_tdo_tlast`, `dma_en`, plus register `0x44` (word count) |
| Block design | `axi_dma` simple mode, MM2S + S2MM, both masters into `ps7/S_AXI_HP0` via a 2-to-1 interconnect; control at `0x40400000`; `jtag0` is the only engine with `dma_en=1` |
| Device tree | `mem=1008M` + `reserved-memory` leaves `0x3F000000..0x3FFFFFFF` free for `/dev/mem` |
| Boot loader | `uEnv.txt` on the FAT partition also carries `mem=1008M` — it **overrides** the device tree `bootargs`, so both must agree |
| Driver | `xvc/tools/xvcdma.c` |

## Verified on hardware

```
engine TAG      0x43C00014 = 0xA7000000
MM2S_DMACR      0x40400000 = 0x00010003
S2MM_DMACR      0x40400030 = 0x00010003
0x43C00044      word counter responds
/proc/cmdline   contains mem=1008M
0x3F000000      readable, inside the reserved pool
```

A 65,536-bit run moved **1917 of 2048 words** (93%) before stalling:

```
0x43C00044 (words left)   0x0083 = 131        <- decremented from 2048
STATUS 0x24               0x00000080          tx_free=128 (TX empty), rx_used=0
STATE 0x30                0x00000004          IDLE, bits=1, busy=0
MM2S_DMASR                0x00001002          bit1 Idle -> MM2S believes it is done
S2MM_DMASR                0x00000000          neither Halted nor Idle -> still running
S2MM_LENGTH               0x00002000          still 8192, not consumed
```

## The stall

The three observations do not fit together:

1. `MM2S` reports Idle, so it handed all 8192 bytes to the stream.
2. The engine popped only 1917 words (`0x44` went 2048 → 131).
3. The TX FIFO is **empty**, so the missing 131 words are not queued there.

With an empty TX FIFO the engine stops shifting, produces no TDO, and `S2MM`
never gets its `TLAST`, so it waits forever. That is the hang.

So the question is **where 131 words went**, not how to break the deadlock.
Candidates, in order of likelihood:

- a lost `tx_push` when the AXI TXD branch and the stream branch resolve in the
  same cycle (both write `tx_push` and `tx_mem[tx_wr]`);
- `s_axis_tdi_tready` deasserting for a cycle that the stream already counted as
  accepted;
- the `tx_full` guard computed from `tx_diff` at a moment when the engine is
  popping, letting one extra word overwrite an unread slot.

## Bugs already fixed during bring-up

| # | Symptom | Cause | Fix |
|---|---|---|---|
| 1 | `opt_design` failed, 103 DRC MDRV-1 | `tx_push` / `tx_mem` driven from two always blocks | merged the DMA push into the AXI write block |
| 2 | same DRC again | `dmaw_left` loaded in the AXI block, decremented in a new block | merged, one block |
| 3 | segfault in `xvcdma` | pointer arithmetic used `-0x380000`; jtag0 is **above** the DMA block | `+0x380000`, and now two separate `mmap`s |
| 4 | `mem=1008M` had no effect | `uEnv.txt` bootargs override the device tree | added `mem=1008M` to `uEnv.txt` too |

## Next steps

1. Instrument: count accepted stream words in RTL and compare with `0x44`.
2. If words are lost in the push arbitration, serialise the two sources.
3. If that is awkward, fall back to **MM2S only** (TDI via DMA, TDO via the
   register path). That removes the whole `TLAST` dependency and still removes
   half the per-word CPU cost.

---

# Root cause (2026-11-12, second pass)

The instrumentation that was proposed as "just add three counters" answers the
question without hardware, because the bug is structural and reproduces in
simulation.

## The counters

`jtag_ctrl` now has three free-running 32-bit counters, cleared only by `rstn`
(the FIFO flush `ctrl_q[2]` deliberately does *not* clear them, so a run can be
bracketed by two software snapshots):

| Offset | Name | Counts |
|---|---|---|
| `0x4C` | `TVALID_CYC` | clocks `m_axis_tdo_tvalid` was high |
| `0x50` | `TREADY_CYC` | clocks `m_axis_tdo_tready` was high |
| `0x54` | `POP_CYC` | clocks a word actually moved (`axis_pop`) |

They wrap after ~43 s at 100 MHz, so read deltas, not absolutes. `xvcdma` now
takes a snapshot every millisecond, prints which counter last advanced, and
names the side that stopped first.

Because `0x4C`/`0x50`/`0x54` are above `0x3F`, the read decode had to widen from
`s_axi_araddr[5:2]` to `[7:2]` — at the old width `0x4C` aliased `0x0C` (TDO).

## Bug A — the AXIS handshake went through registered pulses

`axis_push` / `axis_pop` tapped the stream, but the FIFO pointers advanced one
to two clocks later, via `tx_push` / `rx_pop` registers and then the pointer
block. The AXI-Stream peer samples `tvalid`/`tready` *combinationally*, so the
FIFO kept advertising the occupancy it had two clocks ago.

For the RX side that is fatal: `m_axis_tdo_tvalid` is `!rx_empty`, so after one
transfer the FIFO still looked non-empty, the same word was popped again, and
`rx_rd` walked past `rx_wr`. The pointers are modulo-256 against a 128-deep
FIFO, so `rx_wr - rx_rd` then wraps to a large value — the FIFO looks
permanently non-empty (`tvalid` stuck high) and permanently full, and `pop`
runs away while the engine sees a broken `rx_full` and stops.

Simulated signature, exactly the shape of the hardware hang:

```
tvalid=456 tready=526 pop=456   stream_cnt=2      <- 456 pops for 2 words
```

The push side had the mirror-image hole: a back-to-back burst could write two
words into the same slot.

That is why the three hardware observations did not fit together. `0x44`
decrements on `axis_pop`, so it counted *pops*, not shifted words; the RX FIFO
occupancy (`0x24`) is derived from the same corrupted pointers; and S2MM was
being handed duplicate words, so whether `TLAST` landed on the real last word
was a lottery. There were never "131 missing words".

**Fix:** the transfer cycle is the cycle the pointer moves. `tx_push` and
`rx_pop` are now combinational (`axis_push || axi_txd_wr`, `axis_pop ||
axi_rxd_rd`), `tx_mem` moved into the single FIFO pointer block so the data and
`tx_wr` land together, and the AXI TXD/RXD register path shares the same
expression instead of racing it.

## Bug B — 128-deep FIFOs addressed with an 8-bit pointer

```verilog
reg [31:0] tx_mem [0:127];   // depth 128
... tx_mem[tx_wr] ...        // tx_wr is 8 bits: out of range from 128 on
```

The pointers must be 8-bit so that `write - read` gives occupancy modulo 256,
but every array access has to mask to the 7 real address bits. Vivado truncates
the index silently, so the hardware happened to do the right thing; simulation
read X, which is how it surfaced. Now `tx_mem[tx_wr[6:0]]` and friends.

## Hardware corroboration (no login needed)

The web console at `http://192.168.1.113/cgi-bin/status` reads
`0x14`/`0x18`/`0x24`/`0x28`/`0x30` through `/dev/mem` and needs no login, which
turned out to be enough to confirm Bug A on silicon. Live readings
(saved in `xvc/out/dma_dbg/pl_state_before.json`), channel 0 still holding the
stalled state from the last run:

```
0x28 done       = 131     TDO words actually produced
0x24 rx_used    = 127     of those 131, still sitting in the RX FIFO
0x24 tx_free    = 0       TX full behind it
0x44            = 131     -> 2048 - 131 = 1917 pops counted
```

**1917 pops against 131 words that ever existed, 127 of them still queued.**
A word cannot be popped 14.6 times. That is the double-pop runaway from the
simulation showing up on hardware, and it also explains the "disappearing 131
words": they never disappeared, they were never produced — `0x44` was counting
phantom pops.

## Verification

`xvc/vivado/tb/tb_handshake.v` (Icarus, no Vivado licence needed):

```
iverilog -g2012 -o tb_handshake tb_handshake.v ../rtl/jtag_ctrl.v && ./tb_handshake
```

It checks the old register map still decodes after the `[7:2]` widening, that
the three counters read back what the RTL says, that `0x44` reaches 0 on a
4-word run, that the FIFO flush does not clear the counters, and — the part
that would have caught this months ago — pushes 200 distinct words
back-to-back and compares every word handed to the shift engine with what was
sent. Before the fix it failed with `pop=456` for 2 words; now `pop == words`
and all 200 arrive in order.

## Where this leaves the DMA

```
bitstream  xvc/out/dma_dbg/system_wrapper.bit   md5 ac0d32ea558fba221d2ca268b237c795
driver     xvc/out/dma_dbg/xvcdma              md5 7f09f20d15c5a7f692372828c87f4c96
timing     WNS +0.490 ns  WHS +0.012 ns  THS 0.000 ns   0 critical warnings
```

Build and run steps, and how to read the verdict, are in
[`../out/dma_dbg/README.md`](../out/dma_dbg/README.md).

## Measured on hardware (2026-11-12, after the fix)

Bitstream loaded via the FPGA manager (`echo swap.bin >
/sys/class/fpga_manager/fpga0/firmware`; the driver wants a **byte-swapped**
`.bin`, not Vivado's `.bit` - it says so in `dmesg`). 64 Kbit run, DIV=5:

```
0x4C tvalid = 2048      0x54 pop = 2048      <- one pop per word, exactly
0x44 words left = 0     all armed words consumed, TLAST delivered
0x48 drop = 0           0x24 status = 0x00000080 (rx_used=0, tx_free=128)
MM2S_DMASR = 0x00001002  S2MM_DMASR = 0x00001002   bit1 idle, no error bits
0.0077 s -> 8.55 Mbit/s
```

Repeatable (3 consecutive runs, 2048/2048 each, pop == words every time). The
"which side stops first" question no longer has a stall to find: nothing stops.

### New limit found: 16 KB per transfer

`MM2S_LENGTH` / `S2MM_LENGTH` are only **14 bits wide** in this build, so:

| bytes | LENGTH reads back | result |
|---|---|---|
| 8192 | 0x00002000 | 2048/2048 words, 9.19 Mbit/s |
| 16256 | 0x00003F80 | 4064/4064 words, 9.19 Mbit/s |
| 16384 | 0x00000000 | nothing moves |
| 131072 | 0x00000000 | nothing moves |

The value is truncated modulo 16384, so 16384 and 131072 both program a length
of **0** and the channel never starts. Either set
`CONFIG.c_sg_length_width {23}` on the `axi_dma` in
[`../vivado/build_jtag12p.tcl`](../vivado/build_jtag12p.tcl), or have the driver
re-arm per chunk of <= 16383 bytes. A full bitstream (91 Mbit) needs one of the
two.

Remaining: pick the 16 KB fix, then wire the DMA path into `xvcserver_g1`.
