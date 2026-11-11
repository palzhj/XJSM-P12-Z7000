# Root Cause Found and Fixed: PS7 Configuration Was Never Applied

> 2026-11-01 · Breakthrough finding

## Problem

Our self-built `BOOT.BIN` / `image.ub` cannot boot the board:
- The FSBL is only 65,544 bytes (working version 98,312) → missing SD/QSPI drivers
- `chosen/bootargs` in image.ub is empty → no console, no network
- PetaLinux cannot detect the PS7 SD/UART/ENET → everything is `MANUAL_SELECT`

## Root cause

**`xvc/vivado/tcl/ps7_config.tcl` defines `proc apply_ps7_config {cell}`,
but apart from `build_ext.tcl`, every build script only `source`d it and never called it.**

```tcl
# wrong (this is how all previous jtag12p / g1 / oled build scripts were)
source [file join $script_dir tcl ps7_config.tcl]
create_bd_cell ... processing_system7 ps7
# ← apply_ps7_config is missing!

# correct
source [file join $script_dir tcl ps7_config.tcl]
apply_ps7_config [get_bd_cells ps7]
```

Result: PS7 kept the IP defaults → **all PS peripherals disabled**:

```
PCW_EN_SDIO0 = 0     ← SD card disabled
PCW_EN_QSPI  = 0     ← QSPI disabled
PCW_EN_UART1 = 0     ← serial port disabled
PCW_EN_ENET0 = 0     ← Ethernet disabled
```

## Knock-on consequences

```
PS7 peripherals disabled
  → parameters are 0 in the XSA
    → PetaLinux cannot detect them → config all MANUAL_SELECT
      → FSBL is not built with SD/QSPI drivers (65,544 bytes)
        → the board cannot boot from SD
      → device tree missing nodes + empty bootargs
        → kernel has no console, no network
```

## Fix

### 1. Add the missing call in the build script (`build_jtag12p.tcl`)

```tcl
source [file join $script_dir tcl ps7_config.tcl]
apply_ps7_config [get_bd_cells ps7]
```

### 2. Add the clock that the vendor config enables but is unused

The vendor PS7 configuration enables `S_AXI_HP0`, whose `S_AXI_HP0_ACLK` must be connected to a clock:

```tcl
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/S_AXI_HP0_ACLK]
```

### 3. Write bootargs into `system-user.dtsi`

```dts
/ {
	chosen {
		bootargs = "earlycon console=ttyPS0,115200 clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio";
	};
};
```

## Verification after the fix

### XSA parameters

```
PCW_EN_SDIO0 = 1 ✓
PCW_EN_QSPI  = 1 ✓
PCW_EN_UART1 = 1 ✓
PCW_EN_ENET0 = 1 ✓
```

### PetaLinux device detection (2023.1)

```
CONFIG_SUBSYSTEM_SERIAL_PS7_UART_1_SELECT=y          ✓
CONFIG_SUBSYSTEM_ETHERNET_PS7_ETHERNET_0_SELECT=y    ✓
CONFIG_SUBSYSTEM_PRIMARY_SD_PS7_SD_0_SELECT=y        ✓
CONFIG_SUBSYSTEM_FLASH_PS7_QSPI_0_BANKLESS_SELECT=y  ✓
(all MANUAL_SELECT entries are gone)
```

### FSBL size

| Version | Size |
|---|---|
| Before (broken) | 65,544 ✗ |
| **After fix** | **98,312** ✓ |
| Vendor/archive | 98,312 ✓ **completely identical** |

### Final artifacts

| File | Size | md5 |
|---|---|---|
| **BOOT.BIN** | 5,177,380 | `6df51f2d` |
| **image.ub** | 17,843,768 | `a013672a` |
| zynq_fsbl.elf | 474,264 (BIN 98,312) | `9ec655ef` |

### Device tree in image.ub

```
DT = 21,027 bytes (old working version 20,663)
bootargs = earlycon console=ttyPS0,115200 clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio ✓

Node completeness:
  serial@e0001000  ✓    mmc@e0100000   ✓
  ethernet@e000b000 ✓   spi@e000d000   ✓
  jtag_ctrl        ✓ (our 12-channel PL)
```

## Lessons

**`source`-ing a proc file in a Tcl script is not the same as calling it.**
The build scripts reported no error (the proc defined successfully), but the configuration never took effect,
and every downstream symptom was misdiagnosed as a "PetaLinux version issue / XSA issue".
