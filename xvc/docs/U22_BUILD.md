# Ubuntu 22.04 (VM u22) Build Record

> 2026-10-31 · PetaLinux 2022.2 · Ubuntu 22.04 LTS (VirtualBox `u22`)

## Background

Previously, `BOOT.BIN` / `image.ub` built in a Docker container (Ubuntu 20.04 base) failed to boot several times ✗
This time we built on the Ubuntu 22.04 VM described in the manual ✓

## Results

| Artifact | Size | md5 |
|---|---|---|
| **BOOT.BIN** | 5,101,944 | `f90147cd` |
| **image.ub** | 16,851,896 | `5372a13e` |
| zynq_fsbl.elf | **227,372** | `bc5ce82b` |

### Key comparison: FSBL size

| Environment | zynq_fsbl.elf |
|---|---|
| Archived working version (boots) | 227,332 |
| **Ubuntu 22 VM (this build)** | **227,372** ✓ normal |
| Docker container build | 227,332 → but the BIN is only 65,544 ✗ |
| Version overwritten inside the container | 164,264 ✗ |

→ **The FSBL size produced by the Ubuntu 22 VM is normal** ✓, which is the most promising fix direction.

## Applications included

The root filesystem contains RPMs for all three applications ✓:

```
xvcserver-g1-1.0-r0.rpm    (XVC server, 12 channels)
xvcinfo-1.0-r0.rpm         (status/network/broadcast control)
xvcweb-1.0-r0.rpm          (web pages + init scripts, starts httpd at boot)
```

image.ub is 16 KB larger than the no-application version ✓ consistent with the size of the three small binaries.

## Build procedure

```bash
VBoxManage startvm u22 --type headless

# inside the guest (via guestcontrol or SSH)
cd ~/pl_val/XJSM-P12-Z7000
source /opt/Xilinx/petalinux/2022.2/settings.sh
petalinux-config --get-hw-description=~/pl_val/xsa --silentconfig
petalinux-build                       # 40-60 minutes
petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
    --fpga images/linux/system.bit --u-boot images/linux/u-boot.elf --force
```

### Pitfalls

1. **Importing the XSA resets `rootfs_config`** ✗
   Import the XSA first, **then** append the three lines such as `CONFIG_xvcserver-g1=y`, otherwise the applications do not make it into the image;
2. The first `petalinux-build` ends with
   `ERROR: Failed to build project` (python errors in several `do_*_setscene` tasks),
   but `Tasks Summary: all succeeded` ✓ and the artifacts are complete;
   **build once more with the application config added, and `DONE_RC=0`** ✓;
3. `guestcontrol run` cannot capture stdout ✗ → redirect the output to a file in the guest and read that;
4. In the VM the project is at `~/pl_val/XJSM-P12-Z7000` and the XSA is at `~/pl_val/xsa/`.

## To be verified

⚠️ **Not verified on hardware**: the board's SD card controller is faulty (`MMC: 0 busy timeout`),
so these artifacts need to be tested after the card is replaced and the board recovers.

Expectation: the BOOT.BIN built on the Ubuntu 22 VM should boot normally (the FSBL size is correct).

## Artifact locations

```
xvc/out/u22/            # build artifacts
xvc/out/deliverable/u22/ # delivery copy
```
