# K7 Configuration Flash (S25FL256S) Programming: Complete Solution and Timing

> Chip: **s25fl256sxxxxxx1** (K7 onboard configuration flash)
> Path: Vivado → XVC(2543) → AC7Z020 PL(jtag_ctrl) → K7 TAP → SPI bridge → Flash
> Date: 2026-10-30

## Core conclusion: **the SPI bridge must be programmed before the flash**

```
① program_hw_devices  spi_xc7k325t_pullnone.bit   (2.7 s)
② program_hw_cfgmem   <mcs>                       (197 s, including verify)
```

**Why**: Vivado's flash programming reaches the flash through an "indirect SPI bridge" design.
The GUI's *Program Configuration Memory Device* loads this bridge automatically;
**batch Tcl `program_hw_cfgmem` does not**, so it fails immediately with:

```
ERROR: [Labtools 27-3347] Flash Programming Unsuccessful: Failure to set flash parameters.
```

(On failure it returns within 30~300 ms, with **zero shifts on the XVC server**, because Vivado never reaches the cable.)

## Bridge file location (shipped with Vivado)

```
<Vivado>/2022.2/data/xicom/cfgmem/bitfile.zip
        └── bitfile/spi_xc7k325t_pullnone.bit   (1.42 MB, use this one for K7)
```

There are three variants: `pullnone` / `pullup` / `pulldown`; they make no difference for us, so use `pullnone`.

## Measured timing (over XVC, 10 MHz TCK)

| Stage | Time |
|---|---|
| Program SPI bridge | **2.69 s** |
| Erase + program (31 MB) | **152.7 s** |
| Erase + program + verify | **197.0 s** |
| **Total (with verify)** | **200.7 s ≈ 3.35 minutes** |
| Total (without verify) | **155 s ≈ 2.6 minutes** |

Verification costs about 44 s extra; disable it for fast iteration.

## Script

```bash
vivado -mode batch -source xvc/tools/flash_program_xvc.tcl \
       -tclargs test_bits/top-with-auto-neg.mcs 1     # 1=verify, 0=no verify
```

Output:

```
BRIDGE_OK 2690 ms
FLASH_OK erase+program=196952 ms (verify=1)
TOTAL=200718 ms
```

## GUI path (equivalent, about 6 minutes)

Hardware Manager → right-click `xc7k325t_0` → *Program Configuration Memory Device*
→ select `s25fl256sxxxxxx1-spi-x1_x2_x4` → specify the `.mcs` → OK.

Measured on the server side: 248,171 JTAG shifts, about 6 minutes, `successful`.

## Why it is so slow

Every flash bit in indirect SPI must be emulated by JTAG shifts:

- 31 MB = 248 million bits
- Measured about 1.26 Mbit/s (including SPI command overhead)
- Compared with 9 Mbit/s for FPGA configuration programming (pure shifts, no bridge overhead)

## Speed-up options (if needed later)

1. **Disable verification**: 200.7 s → 155 s
2. **Raise TCK**: 100 ns → 50 ns (requires confirming the K7 link margin)
3. **Build our own SPI bridge**: implement STARTUPE2 + SPI master + JTAG register interface inside the K7,
   which could reach MB/s (31 MB in about 10-20 s), but requires writing a whole new K7 design

---

# KU15P configuration flash (MT25QU01G) — measured 2026-11-13

> Device: **xcku15p** over XVC `192.168.1.113:2543`, TCK 10 MHz
> Flash: **MT25QU01G** (Micron, 1 Gbit / 128 MB), interface SPIX4
> Image: `test_bits/top.mcs` — 34.7 MB payload, `.prm` address range 0..0x03FFFFFF

The board's flash is a **1 Gbit** part, not the 256 Mbit S25FL256S used on the K7.
That matters: the repo's other flash notes reference `s25fl256sxxxxxx1`, and a
34.7 MB image does not fit a 32 MB device. The part is confirmed at run time by
Vivado's ID read:

```
Mfg ID : 20   Memory Type : bb   Memory Capacity : 21   Device ID 1 : 0   Device ID 2 : 0
```

`20` Micron, `21` = 2^21 × 1 Mbit = 1 Gbit.

## The SPI bridge is required here too

The K7 lesson applies unchanged: in batch Tcl `program_hw_cfgmem` does **not**
load the indirect-SPI bridge, and fails in under a second with

```
ERROR: [Labtools 27-3347] Flash Programming Unsuccessful: Failure to set flash parameters.
```

Vivado ships a matching UltraScale bridge inside
`<Vivado>/2022.2/data/xicom/cfgmem/bitfile.zip`:

```
bitfile/spi_xcku15p_pullnone.bit    (7,057,620 bytes)
```

Program that first, then the flash.

## Measured timing

```
STAGE1_START  08:26:56     program spi_xcku15p_pullnone.bit
BRIDGE_MS     11958        = 11.96 s
FLASH_START   08:27:07     erase + program + verify
FLASH_END     08:45:35
TIMING        bridge_ms=11958  flash_ms=1108809  total_ms=1123199
```

| Stage | Time |
|---|---|
| Program SPI bridge (7 MB) | **11.96 s** |
| Erase + program + verify (34.7 MB) | **1108.8 s = 18 min 29 s** |
| **Total** | **1123.2 s = 18 min 43 s** |

That is only **0.25 Mbit/s of payload**. The JTAG link is not the limit — the
server shifted at ~190k words/s (~5.9 Mbit/s) throughout. The time goes into
flash page programming and status-register polling, each of which is a full
JTAG transaction through the bridge. Budget ~19 minutes for a 35 MB image, and
expect it to scale roughly linearly with image size.

For comparison, the same flow on the K7's 31 MB image took 197 s — the KU15P is
~5.6× slower for a similar payload, so the UltraScale bridge is the expensive
part of this path.

## XVC vs local USB cable — measured 2026-11-13

Same board type, same image (`top.mcs`, 34.7 MB), same part (`20/bb/21`, 1 Gbit),
same two-stage bridge flow. Only the transport differs:

```
                      XVC 192.168.1.113:2543      Digilent/210241403684
bridge (7 MB)              11.96 s                    11.29 s
erase+program+verify     1108.81 s                   828.89 s
total                    1123.20 s  (18:43)           842.49 s  (14:02)
payload throughput         0.25 Mbit/s                0.33 Mbit/s
```

| | XVC | USB | USB speedup |
|---|---|---|---|
| Bridge | 11.96 s | 11.29 s | 1.06× |
| Erase+program+verify | 1108.8 s | 828.9 s | **1.34×** |
| **Total** | **18 min 43 s** | **14 min 02 s** | **1.33×** |

Two things this tells us:

- **The bridge stage is identical** (11.3 vs 12.0 s). Programming a 7 MB
  bitstream is dominated by configuration/DONE handling, not by the link, so a
  local cable buys essentially nothing there.
- **The flash stage is only 1.34× faster despite far more link headroom.** If
  JTAG throughput were the limit, USB should have won by 5-10×. It did not, which
  confirms the earlier conclusion: the time is spent in flash page programming
  and status-register polling, and each poll is a round trip that Vivado
  sequences at its own pace.

So for programming this 1 Gbit QSPI with a 35 MB image, **XVC costs about 33%
more wall-clock than a local cable — roughly 4.7 minutes** — which is a modest
price for not needing physical access.

## Flow

```tcl
open_hw_target -xvc_url 192.168.1.113:2543
set dev [lindex [get_hw_devices] 0]; current_hw_device $dev
set_property PROGRAM.FILE <...>/spi_xcku15p_pullnone.bit $dev
program_hw_devices $dev                      ;# stage 1: the bridge

create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {mt25qu01g-spi-x1_x2_x4}] 0]
set cfg [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.BLANK_CHECK 0 $cfg
set_property PROGRAM.ERASE      1 $cfg
set_property PROGRAM.CFG_PROGRAM 1 $cfg
set_property PROGRAM.VERIFY     1 $cfg
set_property PROGRAM.FILES [list test_bits/top.mcs] $cfg
set_property PROGRAM.ADDRESS_RANGE {use_file} $cfg
set_property PROGRAM.PRM_FILE test_bits/top.prm $cfg
program_hw_cfgmem -hw_cfgmem $cfg
```

Note the device is left running the SPI bridge design afterwards, not the user
design — reprogram `top.bit` if the application has to run.
