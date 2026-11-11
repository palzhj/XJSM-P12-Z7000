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
