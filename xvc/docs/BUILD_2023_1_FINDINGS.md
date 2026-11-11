# PetaLinux 2023.1 Build Investigation Log

> 2026-11-01 · Session deep-dive results

## Completed

| Step | Result |
|---|---|
| Rebuild the 12-channel design with Vivado **2023.1** | ✅ Bitstream + `system.xsa` (535 KB, with .bit/.hwh) |
| Create the project with PetaLinux **2023.1** | ✅ `~/pl31/xvc31`, XSA imported successfully |
| Add application recipes | ✅ xvcserver-g1 / xvcinfo / xvcweb |
| Confirm vendor BSP version | ✅ `.petalinux/metadata: PETALINUX_VER=2023.1` |

## The real cause chain behind the build errors (ruled out one by one)

### 1. Download failures ✅ Resolved
```
NetworkAccess('http://petalinux.xilinx.com/.../m4-1.4.19.tar.gz')
```
- Network was intermittently up ✗ → overwrote with the existing `build/downloads` cache (475 files) ✅
- cracklib's git branch was renamed from `master` to `main` ✗ →
  added `recipes-extended/cracklib/cracklib_%%.bbappend` to set `branch=main` ✅
- Result: task progress advanced from 600/4139 to **2512/4139** ✅

### 2. Device tree generation failure ❌ Unresolved
```
Trying to assign a console::$console_ip which doesn't exists !!!
ERROR: [Hsi 55-1443] Error(s) while running TCL procedure post_generate()
```
This means PetaLinux believes there is **no UART console** in the hardware ✗

### 3. Root cause: PetaLinux cannot detect the PS7 peripherals ❌
The project configuration is entirely `MANUAL_SELECT=y` (6 entries):

```
CONFIG_SUBSYSTEM_FSBL_SERIAL_MANUAL_SELECT=y
CONFIG_SUBSYSTEM_SERIAL_MANUAL_SELECT=y
CONFIG_SUBSYSTEM_ETHERNET_MANUAL_SELECT=y
CONFIG_SUBSYSTEM_FLASH_MANUAL_SELECT=y
CONFIG_SUBSYSTEM_PRIMARY_SD_MANUAL_SELECT=y
CONFIG_SUBSYSTEM_RTC_MANUAL_SELECT=y
```

Whereas the vendor BSP names concrete devices:
```
CONFIG_SUBSYSTEM_SERIAL_PS7_UART_1_SELECT=y
CONFIG_SUBSYSTEM_ETHERNET_PS7_ETHERNET_0_SELECT=y
CONFIG_SUBSYSTEM_PRIMARY_SD_PS7_SD_0_SELECT=y
CONFIG_SUBSYSTEM_FLASH_PS7_QSPI_0_BANKLESS_SELECT=y
```

### 4. Hand-editing the config does not work ❌
- Writing directly to `project-spec/configs/config` ✅ write succeeds
- After running `petalinux-build` it is **reverted to MANUAL_SELECT** ✗
- This means these symbols are not in our project's Kconfig (PetaLinux did not generate them from the XSA)

## Conclusion

**Switching PetaLinux versions did not solve the problem** ✗ because:
- The vendor BSP is itself 2023.1 ✅
- But its configuration is **fixed at packaging time** ✅
- When we create a new project, PetaLinux **cannot detect the PS7 peripherals** from our XSA ✗

What really needs solving: **make PetaLinux correctly identify the PS7 SD/UART/ENET from the XSA** ✗

## Viable next steps

1. **Use the vendor BSP project directly** (all config correct ✓), replacing only:
   - `system.bit` → our bitstream
   - application recipes → our three
   Risk: the FSBL's ps7_init comes from the vendor hardware (PS7 configuration is identical ✓ should be fine)

2. Or **give up on auto-detection** and submit an FSBL-only patch to PetaLinux (unverified)

## Practical recommendation

⚠️ The time cost is already high. **Option 1 is recommended**, or simply adopt the already-verified combination:

```
SD card = vendor BOOT.BIN (98,312 FSBL ✓) + our image.ub
```
