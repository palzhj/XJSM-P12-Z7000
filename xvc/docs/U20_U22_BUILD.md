# Ubuntu 20.04 / 22.04 Build Comparison Conclusion

> 2026-10-31 · PetaLinux 2022.2

## Build results from the two VMs

| Artifact | u20 (Ubuntu 20.04) | u22 (Ubuntu 22.04) |
|---|---|---|
| BOOT.BIN | 5,101,944 `f90147cd` | 5,101,944 `f90147cd` ✅ **identical** |
| zynq_fsbl.elf | 227,372 `bc5ce82b` | 227,372 `bc5ce82b` ✅ **identical** |
| image.ub | 16,851,896 `d877d253` | 16,851,896 `5372a13e` (timestamp difference) |

→ **The build environment is not the problem**: both Ubuntu versions produce a byte-identical BOOT.BIN.

## The real problem: the FSBL lacks SD/QSPI drivers

| FSBL | Size | SD/QSPI drivers |
|---|---|---|
| **Archived version (board boots with it)** | **98,312** | ✅ `xsdps.c` `xsdps_options.c` `xqspips.c` `xqspips_options.c` |
| Ours (u20/u22/container) | **65,544** | ❌ All missing (the extra 32 KB is exactly these drivers) |

### Notes

- In the PS7 configuration **both SD0 and QSPI are enabled** (`PCW_EN_SDIO0=1`, `PCW_EN_QSPI=1`, MIO40-45=SD) ✓
- But the compiled FSBL binary contains neither driver ✗
- As a result **the FSBL cannot read BOOT.BIN from SD** → the board hangs silently (exactly the symptom we see)

### Conclusion

The archived `BOOT.BIN` (`b6ae0dfc`) **was most likely provided by the board vendor**,
and our PetaLinux project cannot reproduce the same FSBL ✗

## Recommendation

### Recommended approach (lowest risk)

1. **Keep the archived BOOT.BIN** (`b6ae0dfc`, it boots ✓)
2. **Replace only image.ub** (the newly built `d877d253` / `5372a13e`)
3. If image.ub boots → problem solved ✓
4. If not → investigate the device tree/kernel configuration next

### What not to do

❌ Overwrite the card's copy with our own BOOT.BIN (FSBL has no SD driver → it will definitely not boot)

## Artifact locations

```
xvc/out/u20/    BOOT.BIN  image.ub  zynq_fsbl.elf
xvc/out/u22/    BOOT.BIN  image.ub  zynq_fsbl.elf
```

## Applications included (verified on both VMs)

```
xvcserver-g1  xvcinfo  xvcweb (with /etc/init.d/xvcweb starting automatically at boot)
```
