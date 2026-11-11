# Why Our BOOT.BIN Differs from the Vendor's

> 2026-11-01

## Byte-by-byte comparison conclusion

| BOOT.BIN | Total size | **FSBL** | Rest (bitstream + U-Boot) |
|---|---|---|---|
| Vendor 08_hdmi | 2,683,296 | **98,312** | 2,584,984 |
| Vendor 15_sg_dma | 5,176,200 | **98,312** | 5,077,888 |
| Archived b6ae0dfc | 5,137,208 | **98,312** | 5,038,896 |
| **Ours** | 5,101,944 | **65,544** ✗ | 5,036,400 |

**The difference is only in the FSBL** (the rest differs by just 2.5 KB → the bitstream and U-Boot are essentially identical).

## Where the FSBL differs

The working FSBL is 98,312 bytes, 32 KB more than ours, and its contents include:

```
xsdps.c / xsdps_options.c        ← SD card driver
xqspips.c / xqspips_options.c    ← QSPI driver
"BOOT.BIN"
```

Our FSBL **lacks these drivers** → it cannot read BOOT.BIN from SD → the board hangs silently.

## Why the drivers are missing

Which drivers are compiled into the FSBL is decided by PetaLinux's **automatic hardware detection**:

```
Subsystem AUTO Hardware Settings → SD/SDIO Settings → Primary SD/SDIO
Subsystem AUTO Hardware Settings → Flash Settings  → Primary flash
```

Our project only has:

```
CONFIG_SUBSYSTEM_PRIMARY_SD_MANUAL_SELECT=y    # manual, but no device specified
CONFIG_SUBSYSTEM_FLASH_MANUAL_SELECT=y
```

→ **No device specified** → the FSBL contains no SD/QSPI drivers.

## Fixes attempted (unsuccessful)

1. ❌ Disable `MANUAL_SELECT` so PetaLinux auto-detects
   → after `petalinux-config --silentconfig` it **reverts to `=y`** (meaning no device was detected)
2. `system.hwh` exists in the XSA (130 KB ✓), `PCW_EN_SDIO0=1` ✓ in the PS7 config,
   MIO40-45 = SD ✓ — the hardware description is correct
3. But PetaLinux 2022.2 subsystem auto-detection **does not recognize the PS7 SD/QSPI**

## Conclusion

⚠️ **Our PetaLinux project cannot produce a bootable BOOT.BIN**

You must use:
- The archived `b6ae0dfc` (board factory / early image), or
- The `sd_boot/BOOT.BIN` from the vendor examples (`course_s4_linux/*/sd_boot/`)

Replacing only `image.ub` is safe ✓

## Correct configuration in the vendor BSP (key finding)

After extracting `references/.../course_s4_linux/08_ax_peta_hdmi/hdmi.bsp`, its
`project-spec/configs/config` contains:

```
CONFIG_SUBSYSTEM_PRIMARY_SD_PS7_SD_0_SELECT=y
# CONFIG_SUBSYSTEM_PRIMARY_SD_MANUAL_SELECT is not set
CONFIG_SUBSYSTEM_SD_PS7_SD_0_SELECT=y
CONFIG_SUBSYSTEM_FLASH_PS7_QSPI_0_BANKLESS_SELECT=y
# CONFIG_SUBSYSTEM_FLASH_MANUAL_SELECT is not set
```

**This is the key that makes the FSBL include the SD/QSPI drivers.**

### Why we cannot set it

- These symbols **are not in our project's Kconfig** (`build/misc/config/Kconfig.syshw` only has
  `SUBSYSTEM_PRIMARY_SD_MANUAL_SELECT`)
- Writing them into `config` by hand and then running `petalinux-config --silentconfig` **reverts them to `MANUAL_SELECT=y`** ✗
- This means PetaLinux **did not generate** these device options for our hardware description

### Routes previously tried

1. ❌ Disable MANUAL_SELECT to auto-detect → reverts to `=y`
2. ⚠️ Use the vendor BSP project (`ax_peta`, correct config ✓) with our own XSA imported
   → `petalinux-config --get-hw-description` returns 255 ✗ (unresolved)

## Possible next directions

1. Create the project from the vendor BSP package (`.bsp`) — the BSP ships a complete subsystem configuration
2. Or manually force `-DFSBL_SD_SUPPORT` in the FSBL Makefile (unverified)
3. Or switch to QSPI boot (equally affected by this problem ✗)
