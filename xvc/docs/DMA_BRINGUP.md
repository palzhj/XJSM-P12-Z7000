# DMA bring-up log

Status: **hardware path works end to end, tail synchronisation still stalls.**
Last updated 2026-11-12.

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
