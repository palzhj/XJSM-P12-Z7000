# Session handoff — DMA acceleration for XJSM-P12-Z7000 XVC

Written 2026-11-12 at the end of a long bring-up session, so a fresh session can
pick up without re-deriving anything.

Repository: <https://github.com/palzhj/XJSM-P12-Z7000> — branch `main`,
last commit `861bd43`.

---

## 1. What this project is

A **Broadcast + 12-Engine XVC (Xilinx Virtual Cable) remote JTAG** server running
on an AC7Z020 (Zynq XC7Z020). The PL contains 13 independent JTAG shift engines
(12 channels + 1 broadcast engine) that drive an external AMD Xilinx FPGA scan
chain. Vivado connects to `192.168.1.113:2543` and programs the target as if a
cable were attached.

The work in the last session was **making it faster**. Along the way the
question came down to one thing: the shift engine already runs at the **10 MHz
wire limit**, so the only real lever left is removing the CPU from the per-word
path with **DMA**.

---

## 2. Where performance stands (measured, not estimated)

Tool: `xvc/tools/perfprobe.c`, run on the board.

```
TCK = 10 MHz (fixed requirement, do not raise)

  rd(0x24) STATUS          171 ns
  wr(0x1C) TXD             201 ns
  4 writes + 1 read        973 ns
  32-bit shift (full)     4455 ns   =  7.18 Mbit/s   <- chunked path ceiling
  1 word via FIFO          201 ns   = 159.57 Mbit/s
  FIFO stream 262144 bit  3160 ns/word = 10.13 Mbit/s  <- at the wire limit
  wire time for 32 bit                 =  3200 ns
```

Three conclusions that are **settled** and should not be re-litigated:

1. **The FIFO streaming path already hits 10.13 Mbit/s** on the board when the
   CPU just pushes and drains. It cannot go faster while TCK is 10 MHz.
2. **Over TCP that same run measures only 5.6 Mbit/s.** The remaining loss is in
   the server's software path (bit packing in `get_word`/`put_word`, one mmap
   read per loop iteration), not in JTAG.
3. **The chunked path tops out at 7.18 Mbit/s** because each 32-bit chunk costs
   about 1.26 µs of CPU on top of the 3.2 µs of wire time.

Full bitstream programming reference point: **91,548,512 bits in 15.9 s =
5.76 Mbit/s** on a Kintex-7 325T.

---

## 3. DMA architecture that was built

```
DDR ──MM2S──► jtag0/s_axis_tdi ──► TX FIFO ──► shift engine ──► RX FIFO
                                                                   │
DDR ◄──S2MM── jtag0/m_axis_tdo ◄───────────────────────────────────┘
```

| Layer | Detail |
|---|---|
| `xvc/vivado/rtl/jtag_ctrl.v` | new ports `s_axis_tdi_*`, `m_axis_tdo_*`, `m_axis_tdo_tlast`, `dma_en`; new registers `0x44` (word count that arms TLAST) and `0x48` (drop counter) |
| `xvc/vivado/build_jtag12p.tcl` | `axi_dma` simple mode, MM2S + S2MM, **64-bit** AXI masters, both into `ps7/S_AXI_HP0` through a 2-to-1 `axi_interconnect`; control block at `0x40400000`, Lite port on `axi/M14_AXI` |
| Device tree | `bootargs` gains `mem=1008M`; `reserved-memory` documents `0x3F000000..0x3FFFFFFF` |
| `uEnv.txt` (FAT on SD) | **also** carries `mem=1008M` — it overrides the device tree, so both must agree |
| `xvc/tools/xvcdma.c` | user-space driver: maps `/dev/mem`, does a small TAP setup, arms DMA, polls, reports Mbit/s |

Only **channel 0** is wired to the DMA. The other 12 engines and the broadcast
engine have `dma_en` / `tvalid` / `tready` tied off, so their behaviour is
unchanged.

Register map of the new pieces:

```
0x40400000  MM2S_DMACR      0x40400004  MM2S_DMASR
0x40400018  MM2S_SA         0x40400028  MM2S_LENGTH
0x40400030  S2MM_DMACR      0x40400034  S2MM_DMASR
0x40400048  S2MM_DA         0x40400058  S2MM_LENGTH
0x43C00044  words left (drives TLAST when it reaches 1)
0x43C00048  TDO words dropped because the RX FIFO was full
```

---

## 4. The exact current blocker

> Superseded on 2026-11-12: the blocker was an RTL handshake bug, now fixed and
> verified in simulation. The measurements below are kept as the history that
> led to it. See the "Done — 2026-11-12, second pass" note at the end of this
> section.

Last run: 65,536 bits (2048 TDI words), bitstream `1821c13d`.

```
MM2S_DMACR  = 0x00010003      healthy (RS=1, TAILPEN=1)
S2MM_DMACR  = 0x00010003      healthy
MM2S_DMASR  = 0x00000001      read before LENGTH was written
S2MM_DMASR  = 0x00000001      clean, no error bits
0x43C00044  = 0x00000083      = 131 words left -> 1917 of 2048 words popped
0x43C00048  = 0x0000003F      = 63 TDO words dropped
0x43C00024  = 0x00007F00      rx_used = 127 (full), tx_free = 0 (full)
```

So: **both DMA channels are healthy and 1917 words really moved.** Then the RX
FIFO filled, the shift engine stopped, TX filled behind it, and S2MM stopped
draining. 63 words were dropped rather than corrupting the FIFO.

### Do not chase these — they were already checked and are NOT the problem

| Hypothesis | Verdict |
|---|---|
| `DMACR` bit1 is "Reset" stuck | **Wrong.** In the IP's VHDL, `DMACR_TAILPEN_BIT := 1` and `DMACR_RESET_BIT := 2`. `0x10003` is a normal running value. Reset is bit 2 and the driver writes `4`, which is correct. |
| Scatter-gather was compiled in | No. `c_include_sg = 0` confirmed in the generated `.bd`. |
| HP0 address space missing | No. `SEG_ps7_HP0_DDR_LOWOCM` @ `0x0`, range `1G`, on both `Data_MM2S` and `Data_S2MM`. |
| HP0 data width mismatch | **Was** a bug — masters were 32-bit against a 64-bit `S_AXI_HP0`, causing `DMASlvErr`. Already fixed; `DMASR` is clean after a PL reload. |
| RX FIFO overflow corrupting `rx_diff` | **Was** a bug (occupancy reached 130/128). Guard is now 127 and the push is gated; drop counter added. Already fixed. |

### The next concrete step

Add handshake counters to `jtag_ctrl` and expose them on new register offsets:

```verilog
(* INIT = 32'h0 *) reg [31:0] dbg_tvalid_cyc;  /* cycles m_axis_tvalid was high */
(* INIT = 32'h0 *) reg [31:0] dbg_tready_cyc;  /* cycles m_axis_tready was high */
(* INIT = 32'h0 *) reg [31:0] dbg_pop_cyc;     /* axis_pop pulses              */
```

Then one build answers it outright:

- `tvalid` climbing, `tready` flat → the problem is on the S2MM side
- `tready` climbing, `tvalid` flat → the problem is in the engine
- both climbing, `pop` flat → **handshake logic bug**, most likely

#### Done — 2026-11-12, second pass

The counters are in (`0x4C` `TVALID_CYC`, `0x50` `TREADY_CYC`, `0x54` `POP_CYC`,
free-running, read deltas), and the answer turned out to be the third bullet, in
simulation: `pop` ran away while the engine starved. Root cause is **Bug A** in
[`DMA_BRINGUP.md`](DMA_BRINGUP.md#root-cause-2026-11-12-second-pass) — the AXIS
handshake went through registered pulses, so the FIFO pointers lagged the
transfer, one TDO word was popped twice, and `rx_rd` walked past `rx_wr` into a
bogus modulo-256 "255 words queued" state. **Bug B** was found at the same time:
the 128-deep FIFOs were addressed with an 8-bit pointer. Both fixed; the read
decode had to widen to `addr[7:2]` for the new offsets.

Simulation now shows `pop == words` (a 200-word burst arrives intact and in
order). The bitstream is rebuilt; what is left is only the on-board
re-measurement — see [`../out/dma_dbg/README.md`](../out/dma_dbg/README.md).

Note the earlier claim that 131 words "went missing" was a misreading: `0x44`
counts pops, and pops were not one-per-word.

---

## 5. Environment (essential to reproduce anything)

### Board

```
IP            192.168.1.113
console       /dev/ttyUSB0 (CP2102N, 115200 8N1)
login         root / (set when the image was built)
XVC ports     2542 broadcast, 2543 channel 0
TCK           fixed 10 MHz, `-d 5`
```

`/dev/ttyUSB2` is an FTDI FT232R that is the **JTAG cable's UART**, not a
console — it produces nothing at any baud rate.

Run only **one** `xvcserver_g1`; the second one fails to `bind` silently.
`pkill` does not exist on the board; use
`for p in $(pidof xvcserver_g1); do kill -9 $p; done`.

### JTAG cables (all on `localhost:3121`)

| Target | Devices | Role |
|---|---|---|
| `Digilent/210512180081` | `arm_dap_0` + `xc7z020_1` | **the Zynq itself** — use this to program the PL |
| `Digilent/210249B1B270` | `xc7k325t_0` + `xc7a50t_1` | separate K7/A7 board |
| `Digilent/210249B2B920` | `xc7s25_0` | separate Spartan-7 board |
| `Digilent/210241403684` | — | will not open |
| XVC `192.168.1.113:2543` | `xcku15p_0` | **the target through our XVC**, KU15P, IRLEN 6 |

Program the PL without touching the SD card:

```tcl
open_hw_manager
connect_hw_server -url localhost:3121 -allow_non_jtag
open_hw_target localhost:3121/xilinx_tcf/Digilent/210512180081
set dev [lindex [get_hw_devices xc7z020*] 0]
current_hw_device $dev
set_property PROGRAM.FILE xvc/vivado/work_jtag12p/jtag12p.runs/impl_1/system_wrapper.bit $dev
program_hw_devices $dev
```

### Vivado and the cross toolchain

```
Vivado 2022.2    /opt/Xilinx/Vivado/2022.2
PetaLinux 2023.1 /opt/Xilinx/petalinux/2023.1
bitstream build  vivado -mode batch -source xvc/vivado/build_jtag12p.tcl    (~15 min)
PetaLinux build  inside the VirtualBox VM `u20`, ~/work/xvc2, petalinux-build (~20 min)
```

Cross-compiling on the host does **not** work; the ARM toolchain lives in the
VM. The working invocation (guest):

```bash
CC=$HOME/work/xvc2/build/tmp/sysroots-components/x86_64/gcc-cross-arm/usr/bin/arm-xilinx-linux-gnueabi/arm-xilinx-linux-gnueabi-gcc
SR=$HOME/work/xvc2/build/tmp/work/zynq_generic_7z020-xilinx-linux-gnueabi/linux-xlnx/6.1.5-xilinx-v2023.1+gitAUTOINC+716921b6d7-r0/recipe-sysroot
RN=$HOME/work/xvc2/build/tmp/work/zynq_generic_7z020-xilinx-linux-gnueabi/linux-xlnx/6.1.5-xilinx-v2023.1+gitAUTOINC+716921b6d7-r0/recipe-sysroot-native
export COMPILER_PATH=$RN/usr/bin/arm-xilinx-linux-gnueabi:$RN/usr/libexec/arm-xilinx-linux-gnueabi/gcc/arm-xilinx-linux-gnueabi/12.2.0
export PATH=$RN/usr/bin/arm-xilinx-linux-gnueabi:$PATH
$CC --sysroot=$SR -march=armv7-a -mfpu=neon -mfloat-abi=hard -O2 -o out src.c
```

The host shares files with the VM through `/media/sf_a435849f-.../work/XJSM-P12-Z7000`.
Guest-to-host copies through `sg vboxsf -c "cp ..."` **fail silently** sometimes —
always `md5sum` both ends before trusting a build.

Deploy binaries to the board with the host's HTTP server:

```bash
cd /tmp/www2 && python3 -m http.server 8033 --bind 192.168.1.50
# on the board: wget -q http://192.168.1.50:8033/<file> -O <file> && chmod +x
```

---

## 6. Gotchas that cost hours

1. **`uEnv.txt` on the FAT partition overrides the device-tree `bootargs`.**
   Adding `mem=` only in the DT has no effect. Both must carry it.
2. **The board can write its own SD card.** No need to be in the lab:
   `/dev/mmcblk0p1` is already mounted at `/run/media/BOOT-mmcblk0p1`.
   Back up first (`cp BOOT.BIN BOOT.BIN.v12`), write, `sync`, `reboot`.
   There are already `BOOT.BIN.v12` / `image.ub.v12` backups on the card.
3. **`petalinux-package --boot` may produce a `BOOT.BIN` with an unchanged md5**
   even when `system.bit` changed, because a previous run already embedded it.
   Verify by programming and reading a register, not by md5.
4. **Vivado multi-driver rules**: `tx_push`, `rx_pop`, `tx_mem`, `dmaw_left` must
   each be driven from exactly one `always` block. Two attempts at this produced
   `MDRV-1` and failed `opt_design`.
5. **`connect_bd_net` on `ps7/S_AXI_HP0_ACLK` fails** because Vivado wires it
   automatically. Do not add it.
6. **`NUM_MI` must be set when the interconnect is created**, not later, or the
   `M14_ACLK` pin does not exist yet when you try to connect it.
7. **Buffer stdout is a trap.** A driver that hangs with `stdout` redirected to a
   file shows nothing. Use `setvbuf(stdout, NULL, _IONBF, 0)`.
8. **`s_axis_tdi` needs no bookkeeping but S2MM requires TLAST** — confirmed by
   AMD KB 60053 — which is why register `0x44` exists.

---

## 7. State of the extras

- **FIFO streaming** (register-driven, no DMA) is enabled, verified 100% bit-exact
  at 1 Mbit through a KU15P, and is the same speed as the chunked path. Flagged
  in `KNOWN_ISSUES` #35 as fixed, and item G as "correct but no faster".
- **DMA** is where section 4 leaves it.
- The runtime-replaced binaries (`xvcserver_g1`, `xvcinfo`, `oled_ip`) are **lost
  on reboot** unless the image is rebuilt. After the last rebuild the image
  contains the fixed server, so this is currently fine.
- Regression suite: `xvc/tests/fulltest_v12.py`, 76 checks, all passing on the
  pre-DMA bitstream. Not yet re-run against the DMA bitstream.

---

## 8. Suggested opening prompt for the next session

> Continue the DMA work on XJSM-P12-Z7000. Read `xvc/docs/DMA_BRINGUP.md` and
> `xvc/docs/SESSION_HANDOFF.md` first. The two DMA channels are healthy and 1917
> of 2048 words moved before the RX FIFO filled and S2MM stopped draining. Add
> `tvalid` / `tready` / `pop` cycle counters to `jtag_ctrl`, expose them on new
> register offsets, rebuild, and measure which side stops first.
