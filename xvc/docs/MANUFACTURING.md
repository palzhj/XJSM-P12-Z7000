# XJSM-P12-Z7000 Mass Production Programming Work Instruction

> Intended for: production-line programming station, test station, repair station
> Applicable product: AC7Z020 (XC7Z020-CLG400) carrier board + external AMD Xilinx FPGA expansion
> Version: **v12** (2026-11-04, includes the critical TCP shift bug fix + final OLED layout)
> Prepared by: XVC Project Team

---

## Table of Contents

1. [Deliverables](#1-deliverables)
2. [Choosing a Method](#2-choosing-a-method)
3. [Method A: SD Card Batch Duplication (Recommended)](#3-method-a-sd-card-batch-duplication-recommended)
4. [Method B: QSPI Flash Programming (Requires Hardware Support)](#4-method-b-qspi-flash-programming-requires-hardware-support)
5. [Method C: JTAG Programming (Engineering / Rework)](#5-method-c-jtag-programming-engineering--rework)
6. [Boot Mode Setting](#6-boot-mode-setting)
7. [Factory Test Procedure](#7-factory-test-procedure)
8. [Serial Number and MAC Address Management](#8-serial-number-and-mac-address-management)
9. [Common Faults and Handling](#9-common-faults-and-handling)
10. [Version Management and Traceability](#10-version-management-and-traceability)
11. [Appendix A: Command Quick Reference](#appendix-a-command-quick-reference)
12. [Appendix B: File Checksums](#appendix-b-file-checksums)

---

## 1. Deliverables

### 1.1 The Two Files Required for Programming

| File | Size | Function | Medium |
|---|---|---|---|
| `BOOT.BIN` | 5,177,792 B | FSBL + bitstream + U-Boot | Root directory of the FAT partition on the SD card |
| `image.ub` | 17,870,984 B | Kernel + device tree + root filesystem (initramfs) | Same as above |

**Total approx. 23 MB** ✓ A single 4 GB SD card is sufficient ✓

### 1.2 Optional Files (not used for boot)

| File | Purpose |
|---|---|
| `system.bit` | Reload PL alone (for debugging) |
| `system.xsa` | Hardware platform (for Vivado / Vitis) |
| `xvcserver_g1` | XVC server (already inside image.ub; this is a standalone copy) |
| `xvcinfo` | Register debugging tool |
| `oled_ip` / `i2cprobe` | OLED display / I2C scan |

### 1.3 Directory Structure (Release Package)

```
xvc_v12/
├── sd_card/
│   ├── BOOT.BIN           ← required
│   └── image.ub           ← required
├── fpga/
│   ├── system.bit
│   └── system.xsa
├── sw/
│   ├── xvcserver_g1
│   ├── xvcinfo
│   ├── oled_ip
│   ├── i2cprobe
│   ├── index.html         (Web console)
│   └── control            (CGI)
├── docs/
└── README.txt
```

---

## 2. Choosing a Method

| Method | Time per board | Equipment | Suitable volume | Recommendation |
|---|---|---|---|---|
| **A. SD card copy** | 3 minutes | Card reader ×1 + master card ×1 | Any | ⭐⭐⭐⭐⭐ |
| **B. QSPI programming** | 8 minutes | JTAG downloader ×1 | Medium to large volume | ⭐⭐⭐ (requires hardware support) |
| **C. JTAG programming** | 15 minutes | JTAG downloader ×1 | Prototyping / rework | ⭐⭐ |

### Why Method A Is Preferred

This carrier board **has no QSPI Flash** (measured: `/proc/mtd` is empty and `/proc/cmdline` has no `root=`, which means it boots from initramfs) ✓
The whole system runs from the ramdisk inside `image.ub` ✓ **The SD card is the only boot medium** ✓

- No QSPI → no need to erase and write Flash ✓
- No eMMC → no partitioning tools needed ✓
- **Pull the card to change versions** ✓ The most convenient way to upgrade in the field ✓
- Changing the system on one board takes **< 30 seconds** ✓ Lowest rework cost on the line ✓

---

## 3. Method A: SD Card Batch Duplication (Recommended)

### 3.1 Preparing the Master Card (one-time, by Engineering)

**Hardware**: one good-quality SDHC card (4–16 GB, Class 10 recommended)

**Steps**:

```bash
# 1. Confirm the card device name (check carefully, a mistake will destroy a disk)
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# 2. Wipe and create a FAT32 partition
sudo dd if=/dev/zero of=/dev/sdX bs=1M count=8
sudo parted -s /dev/sdX mklabel msdos
sudo parted -s /dev/sdX mkpart primary fat32 1MiB 100%

# 3. Format
sudo mkfs.vfat -F 32 -n BOOT /dev/sdX1

# 4. Mount and copy
sudo mkdir -p /mnt/boot
sudo mount /dev/sdX1 /mnt/boot
sudo cp BOOT.BIN image.ub /mnt/boot/
sync
sudo umount /mnt/boot
```

**Verification**:

```bash
sudo mount /dev/sdX1 /mnt/boot
md5sum /mnt/boot/BOOT.BIN /mnt/boot/image.ub
sudo umount /mnt/boot
```

Must match the checksums in [Appendix B](#appendix-b-file-checksums) ✓

**Log the master card**: apply the label `XJSM-P12-Z7000 MASTER v12` and **archive it under lock** ✓

### 3.2 Imaging the Master Card (recommended, copies are faster afterwards)

Back up the whole master card as an image file, then write the image directly on the line ✓ Avoids filesystem fragmentation differences ✓

```bash
# Back up (size follows the real capacity; a 4 GB card gives an approx. 4 GB image)
sudo dd if=/dev/sdX of=/data/images/xvc_v12_sd.img bs=4M conv=fsync status=progress

# approx. 20 MB after compression
gzip -9 /data/images/xvc_v12_sd.img
ls -lh /data/images/xvc_v12_sd.img.gz
```

**The master image checksum is recorded in [Appendix B](#appendix-b-file-checksums)** ✓

### 3.3 Production-Line Batch Duplication

**Configuration per station**:
- Card reader (USB 3.0 recommended, 3× faster)
- Programming host running Linux (or Windows with Win32DiskImager)
- Label printer (writes the serial number)

**Linux one-shot script** (placed on the station at `/opt/program_sd.sh`):

```bash
#!/bin/bash
# Usage: ./program_sd.sh <card device> <serial number>
set -e
DEV="$1"
SN="$2"
IMG="/data/images/xvc_v12_sd.img"
[ -z "$DEV" ] || [ -z "$SN" ] && { echo "Usage: $0 /dev/sdX SN0001"; exit 1; }

echo "=== Writing $IMG to $DEV ==="
sudo umount ${DEV}* 2>/dev/null || true
sudo dd if="$IMG" of="$DEV" bs=4M conv=fsync status=progress
sync

echo "=== Writing serial number ==="
MNT=$(mktemp -d)
sudo mount ${DEV}1 "$MNT"
# The serial number goes on the FAT partition (the rootfs is a ramdisk, not writable at runtime)
printf "SN=%s\nBUILD=v8\nDATE=%s\n" "$SN" "$(date +%F)" | sudo tee "$MNT/SN.TXT" >/dev/null
sync
sudo umount "$MNT"
rmdir "$MNT"

echo "=== Verify ==="
sudo mount ${DEV}1 "$MNT"
md5sum "$MNT/BOOT.BIN" "$MNT/image.ub"
sudo umount "$MNT"
echo "=== Done: $SN ==="
```

**Time per card**: writing a 4 GB image at 30 MB/s ≈ 2.5 minutes ✓

### 3.4 Multiple Stations in Parallel

| Stations | Recommended reader | Cycle time |
|---|---|---|
| 1 | 1 port | 3 minutes/board |
| 4 | 4-port HUB | 4 boards in parallel, still 3 minutes/batch |
| 8 | 8-port HUB + multiple processes | 3 minutes/8 boards |

**`dd` can run as multiple parallel processes** (each writes its own card):

```bash
for i in 1 2 3 4; do
  ./program_sd.sh /dev/sd$i SN$(printf "%04d" $i) &
done
wait
```

---

## 4. Method B: QSPI Flash Programming (Requires Hardware Support)

> ⚠️ **Prerequisite**: the carrier board must **have a QSPI NOR Flash fitted** (typical parts W25Q256 / MX25L256, 32 MB)
> and the kernel must enable `CONFIG_MTD_SPI_NOR` ✗ the current image **does not enable it** ✓

### 4.1 Verify That the Hardware Exists

Run the following on the board under Linux:

```bash
cat /proc/mtd          # if mtd0 etc. appear, the Flash exists
dmesg | grep -i spi-nor
```

**Measured on the current production board: `/proc/mtd` is empty → no QSPI → this method does not apply** ✓

### 4.2 Programming Steps (JTAG) if QSPI Is Confirmed

```tcl
# Connect the downloader
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

# Select the Flash
create_hw_cfgmem -hw_device $dev [lindex [get_cfgmem_parts {s25fl256sxxxxxx0-spi-x1_x2_x4}] 0]
set mem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.BLANK_CHECK   0 $mem
set_property PROGRAM.ERASE         1 $mem
set_property PROGRAM.CFG_PROGRAM   1 $mem
set_property PROGRAM.VERIFY        1 $mem
set_property PROGRAM.CHECKSUM      0 $mem

# Program (BOOT.BIN must be in the QSPI format produced by bootgen)
set_property PROGRAM.FILES [list "BOOT.BIN"] $mem
set_property PROGRAM.PRM_FILE "" $mem
set_property PROGRAM.ADDRESS_RANGE {use_file} $mem

program_hw_cfgmem -hw_cfgmem $mem
```

**Time**: erasing, writing and verifying a 32 MB Flash takes about **6–10 minutes** ✓

### 4.3 QSPI Boot Mode

After programming, move the boot mode jumper to **QSPI** ✓ see [Section 6](#6-boot-mode-setting) ✓

---

## 5. Method C: JTAG Programming (Engineering / Rework)

**Purpose**: prototyping, rework, urgent version changes (without touching the SD card)

### 5.1 Reload PL Only (without reinstalling Linux)

```tcl
open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROGRAM.FILE {system.bit} $dev
program_hw_devices $dev
refresh_hw_device $dev
```

**Time**: about **10 seconds** ✓

> ⚠️ **Important**: after reloading PL you **must restart the XVC server** ✗
> because the PL registers are cleared ✗ `DIV` returns to its default value of 8 (6.25 MHz) ✗
> ```bash
> killall xvcserver_g1; /usr/bin/xvcserver_g1 -a 0x43C00000 -d 5 &
> devmem 0x43C00018 32     # should read back 0x5
> ```

### 5.2 Full Reinstall (FSBL + bitstream + U-Boot)

```tcl
set_property PROGRAM.FILE {BOOT.BIN} $dev
program_hw_devices $dev
```

> Note: programming BOOT.BIN directly over JTAG **is not persistent** ✗ it is lost on power-down ✗
> Persistence requires the SD card (Method A) or QSPI (Method B) ✓

### 5.3 Serial Console Login (for debugging)

| Item | Value |
|---|---|
| Device | `/dev/ttyUSB3` (Silicon Labs CP210x) |
| Baud rate | 115200 8N1 |
| Username | `root` / `iheper` |
| Password | Set per unit at programming time (see 8.4) |

---

## 6. Boot Mode Setting

The Zynq boot mode is determined by the **MIO[5:3]** levels at reset ✓ set by the DIP switch / jumper position ✓

| Mode | MIO5 | MIO4 | MIO3 | Note |
|---|---|---|---|---|
| **JTAG** | 0 | 0 | 0 | For engineering |
| **QSPI** | 0 | 0 | 1 | Method B |
| **SD** | 0 | 1 | 0 | **For production (Method A)** ✓ |
| NAND | 1 | 0 | 0 | Not supported |

**Production requirement**: set the jumper to **SD** before programming ✓ and tick the box on the inspection form ✓

---

## 7. Factory Test Procedure

### 7.1 Board Test Steps (5 minutes per board recommended)

| # | Step | Method | Pass criteria |
|---|---|---|---|
| **1** | Visual inspection | Visual | No missing components, no shorts, SD card slot not deformed |
| **2** | Power-on | 12 V / 3 A | Current < 1.2 A, no abnormal heating |
| **3** | OLED lights up | Visual | Shows IP + 12 port boxes + the `Broadcast` row |
| **4** | Serial boot | Connect at 115200 | Prints U-Boot / kernel logs, no `Kernel panic` |
| **5** | Login | `root` / the password set for this unit | Reaches the shell |
| **6** | Network | `ip addr show eth0` | Obtains an IP (DHCP) or a static IP is written |
| **7** | **13 ports** | `ss -ltn \| grep -c 25[4-5][0-9]` | **= 13** ✓ |
| **8** | **Engine TAG** | `devmem 0x43C00014 32` | `0xA7000000` ✓ |
| **9** | **Broadcast register** | `devmem 0x43CD000C 32` | `0xB7000000` ✓ |
| **10** | **XVC handshake** | `printf 'getinfo:' \| nc 127.0.0.1 2543` | Returns `xvcServer_v1.0:4194304` ✓ |
| **11** | **Handshake on all 12 channels** | Loop over 2543–2554 | All return ✓ |
| **12** | **Broadcast session** | `nc 127.0.0.1 2542` → `getinfo:` | Returns ✓ |
| **13** | **Broadcast exclusivity** | Connect to 2543 after a broadcast is established | **Rejected** ✓ |
| **14** | **TCK frequency** | `devmem 0x43C00018 32` | `0x5` (= 10 MHz) ✓ |
| **15** | **OLED port indicator** | Connect to 2546 (port 4) | The `4` on the screen becomes filled ✓ |
| **16** | **Web console** | Open `http://<IP>/` in a browser | Page loads correctly, `TX used` header present ✓ |
| **17** | Reset and reboot | Power off for 10 seconds, then power on | Steps 3–7 pass again ✓ |
| **18** | **Automated test** | Run `fulltest_v12.py --net-only` | **73/73 pass, exit code 0** ✓ |

### 7.2 Run Everything with One Command (Recommended)

**On your own PC** (does not consume board resources, can run in parallel batches):

```bash
python3 fulltest_v12.py                # Full: network + serial, 73 items
python3 fulltest_v12.py --net-only     # Network only, quick production-line check
```

Exit code **0 = all passed**, so it can be wired straight into production-line automation ✓

### 7.2.1 Test Suite Coverage (73 items)

| Group | Content | Items |
|---|---|---|
| **A** | Network and Web console (ping / index / 3 CGI) | 6 |
| **B** | getinfo on 13 XVC ports | 5 |
| **C** | **Protocol boundaries**: settck with 6 periods (binary), shift over **21 bit widths** (1…8192 bit), TDI in 6 patterns, 3 illegal inputs | 34 |
| **D** | engine registers (12 channels + broadcast) (TAG / DIV / STATUS / go_seq / state) | 6 |
| **E** | Broadcast register block (TAG / BCMASK read-write / CHSEL read-write / CTRL) | 5 |
| **F** | Concurrency and exclusivity (double connect on the same channel / 12 channels online at once) | 2 |
| **G** | Broadcast lifecycle (establish / refuse single connect / internal shift / recovery after disconnect / dual broadcast) | 5 |
| **H** | Robustness (rapid reconnect ×30 / disconnect mid-transfer / 65536 bit / **524288 bit**) | 4 |
| **I** | OLED (process count / I2C ACK) | 2 |

**v12 measured: all 73/73 pass** ✓

### 7.2.2 Critical Boundary Values (common pitfalls)

| Item | Description |
|---|---|
| `settck:` | The period must be **4 bytes of binary in network order**, not ASCII text ✗ |
| `shift:` | The bit count is likewise 4 bytes **big-endian** |
| `shift:0` | Must be rejected (without dropping the server) |
| shift > 4194304 | Must be rejected |
| shift inside a broadcast session | Must **reuse the same TCP connection**, a new one is not allowed ✗ |
| Rapid reconnect | The server waits at most 1.5 seconds for the previous session to exit |

### 7.3 Factory Inspection Record Form

```
┌──────────────────────────────────────────────────────────┐
│ XJSM-P12-Z7000 Factory Inspection Record                 │
├──────────────────────────────────────────────────────────┤
│ Serial No.:  SN________________     Date: 20__-__-__     │
│ Programmed version: v8    BOOT.BIN md5: 835b4152         │
│                           image.ub  md5: d8685f59        │
├──────────────────────────────────────────────────────────┤
│ [ ] 1  Visual inspection     [ ] 2  Power-on current     │
│ [ ] 3  OLED                  [ ] 4  Serial boot          │
│ [ ] 5  Login                 [ ] 6  Network              │
│ [ ] 7  13 ports              [ ] 8  Engine TAG           │
│ [ ] 9  Broadcast register    [ ] 10 XVC handshake        │
│ [ ] 11 12 channels           [ ] 12 Broadcast session    │
│ [ ] 13 Broadcast exclusivity [ ] 14 TCK frequency        │
│ [ ] 15 OLED indicator        [ ] 16 Web console          │
│ [ ] 17 Reset and reboot                                  │
│ [ ] 18 fulltest_v12.py auto test (73 items)              │
├──────────────────────────────────────────────────────────┤
│ Result:  [ ] PASS    [ ] FAIL (reason:________________)  │
│ Inspector: ________         Reviewer: ________           │
└──────────────────────────────────────────────────────────┘
```

---

## 8. Serial Number and MAC Address Management

### 8.1 Writing the Serial Number

The root filesystem is a **ramdisk (read-only, lost on power-down)** ✗ so the serial number must be written to the **FAT partition of the SD card** ✓

**Location**: `SN.TXT` in the SD card root directory

```
SN=SN000123
BUILD=v8
DATE=2026-11-05
MAC=00:0A:35:01:23:45
```

**How to read it** (on the board):

```bash
cat /mnt/sn/SN.TXT     # if already mounted
# or
mount /dev/mmcblk0p1 /mnt && cat /mnt/SN.TXT
```

### 8.2 MAC Address

By default the Zynq MAC is read by `u-boot` from the environment ✓ otherwise it is random ✗

| Method | Approach | Recommendation |
|---|---|---|
| **A. Write the SD card per board** | MAC carried in `SN.TXT`; the boot script runs `ifconfig eth0 hw ether` ✓ | ⭐⭐⭐⭐ |
| **B. Store in the U-Boot environment** | Requires one boot first, then `saveenv` ✗ one extra process step ✗ | ⭐⭐ |
| **C. No management (random)** | Risk of conflicts within the same subnet ✗ | ✗ |

**Line allocation**: the MAC range is assigned centrally by network administration ✓ one per board ✓ recorded in `SN.TXT` and in the database ✓

### 8.4 Account Credentials

**No password ships in this repository** ✗ Each production image gets its own.

The image is built with placeholders in
`project-spec/meta-user/recipes-core/images/petalinux-image-minimal.bbappend`:

```bitbake
EXTRA_USERS_PARAMS = "usermod -p '\$6\$REPLACE_ME_SALT\$REPLACE_ME_HASH' root; ..."
```

An invalid hash means the image still builds and boots but **nobody can log in** ✗
That is the safe default: better an image nobody can enter than one with a
published password.

**Before building a production batch:**

```bash
# 1) pick a per-batch root password and hash it
openssl passwd -6 '<your-root-password>'

# 2) paste the hash into the bbappend, escaping every $ as \$
#    (bitbake expands $VAR and would corrupt the hash)

# 3) build, then confirm the hash actually landed in the image
petalinux-build
# unpack rootfs.cpio from image.ub and check /etc/shadow:
#   root:$6$<your-salt>$<your-hash>
```

**Per-unit passwords** (recommended when a board leaves the factory with network
access): after first boot, log in and run `passwd`, then record the password in
the unit's production record ✗ never in a shared document ✓

| Item | Rule |
|---|---|
| Root password | Unique per batch minimum, per unit if the board is customer-accessible |
| Recording | In the production database, never in the repo or this manual |
| `xvc` user | Unprivileged, used for remote login; same rules apply |
| `securetty` | `ttyPS0` / `ttyPS1` are added by the bbappend so root can use the UART |

### 8.3 Recommended Serial Number Encoding

```
SN 0 0 1 2 3 4
   │ │ └─┬─┘ └── serial number 0001–9999
   │ │   └──────── last two digits of the year (26 = 2026)
   │ └──────────── production line code (0 = main line)
   └────────────── product code (S = XJSM-P12-Z7000)
```

Example: `SS260001` = 2026, main line, unit 1 ✓

---

## 9. Common Faults and Handling

| Symptom | Cause | Action |
|---|---|---|
| **No output at all after power-on** | Wrong boot mode / card not inserted properly | Check the jumper (should be SD) ✓ reseat the card ✓ |
| **FSBL on serial but no kernel** | `image.ub` missing or corrupt | Re-copy `image.ub` ✓ verify the md5 ✓ |
| **`Kernel panic - not syncing`** | `image.ub` version does not match `BOOT.BIN` | Both must be updated **as a pair** ✓ |
| **No network** | PHY not reset / cable / no DHCP response | `ifconfig eth0 up` ✓ replace the cable ✓ |
| **OLED completely dark** | No I2C ACK / wrong bitstream | `i2cprobe /dev/i2c-1` should show `ACK 0x3C` ✓ |
| **OLED ghosts / flickers** | **Several oled processes running at once** ✗ | `kill -9 $(ps \| grep oled \| awk '{print $1}')` ✓ |
| **Cannot connect to a port** | Server not started | `pidof xvcserver_g1` ✓ if absent, start it manually ✓ |
| **XVC returns nothing** | Bitstream not loaded / wrong TAG | `devmem 0x43C00014 32` should be `0xA7000000` ✓ |
| **TCK is only 6.25 MHz** | Server not restarted after PL reload | Restart `xvcserver_g1` ✓ |
| **Cannot connect to broadcast** | Already occupied / mask conflict | Check the mask with `devmem 0x43CD0004 32` ✓ |

### ⚠️ Special Note: `pkill` **Does Not Exist** on This System

busybox was built without `pkill` ✗ every cleanup script containing `pkill` **fails silently** ✗
Use instead:

```bash
kill -9 $(ps | grep '/tmp/oled_' | grep -v grep | awk '{print $1}')
```

---

## 10. Version Management and Traceability

### 10.1 Version Number Rules

```
v8  = 8th mass production version
```

**Record the following for every version**:

| Item | Example |
|---|---|
| Version number | v8 |
| Date | 2026-11-05 |
| `BOOT.BIN` md5 | `835b415252fe70d7b8522620578bda28` |
| `image.ub` md5 | `d8685f59...` |
| Bitstream md5 | `7272de4272ca910779471c30b0d86584` |
| FSBL size | 98,312 B |
| Change summary | Added OLED display, broadcast engine, I2C EMIO |
| Master card / master image ID | MASTER-008 |

### 10.2 Master Card Control Policy

| Item | Requirement |
|---|---|
| Quantity | ≥ 2 (one in use, one spare) |
| Storage | Anti-static bag + locked cabinet |
| Label | `MASTER v12 / date / first 8 md5 chars` |
| Audit | Sample-check once a month, compare the md5 with the master image |
| Scrapping | Scrap if write protection fails or the card was modified by mistake |

### 10.3 Traceability Chain

```
product serial number (SN.TXT)
   ↓
programmed version (v8)
   ↓
BOOT.BIN md5 + image.ub md5
   ↓
master image file (xvc_v12_sd.img.gz) md5
   ↓
release package (xvc_v8.tar.gz) md5
```

**A problem at any layer can be traced back to its source** ✓

---

## Appendix A: Command Quick Reference

### A.1 Programming Station

```bash
# List the card
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

# Write the master image
sudo dd if=xvc_v12_sd.img of=/dev/sdX bs=4M conv=fsync status=progress && sync

# Verify
sudo mount /dev/sdX1 /mnt && md5sum /mnt/BOOT.BIN /mnt/image.ub && sudo umount /mnt

# Write the serial number
printf "SN=SS260001\nBUILD=v8\nMAC=00:0A:35:01:23:45\n" | sudo tee /mnt/SN.TXT
```

### A.2 Test Station (on the board)

```bash
# System information
uname -a; free -m; df -h
cat /proc/cmdline

# Network
ip addr show eth0
ip route

# 13 ports
ss -ltn | grep -E ':(2542|254[3-9]|255[0-4]) ' | wc -l    # should be 13

# Registers
devmem 0x43C00014 32      # engine TAG   expected 0xA7000000
devmem 0x43C00018 32      # DIV_RB       expected 0x5 (=10MHz)
devmem 0x43CD000C 32      # broadcast TAG   expected 0xB7000000
devmem 0x43CD0004 32      # broadcast mask  expected 0x00000FFF

# XVC handshake
printf 'getinfo:' | timeout 3 nc 127.0.0.1 2543
# expected: xvcServer_v1.0:4194304

# Test all 12 channels
for p in $(seq 2543 2554); do
  echo -n "$p: "; printf 'getinfo:' | timeout 2 nc 127.0.0.1 $p || echo FAIL
done

# Broadcast session
printf 'getinfo:' | timeout 3 nc 127.0.0.1 2542

# OLED
i2cprobe /dev/i2c-1        # should show ACK 0x3C
ps | grep oled_            # only 1 allowed

# Server status
pidof xvcserver_g1
tail -20 /var/log/messages
```

### A.3 Rework Station

```bash
# Stop all OLED instances (note: there is no pkill)
kill -9 $(ps | grep '/tmp/oled_' | grep -v grep | awk '{print $1}')

# Restart the server (mandatory after a PL reload)
killall xvcserver_g1 2>/dev/null
/usr/bin/xvcserver_g1 -a 0x43C00000 -d 5 &

# Reload PL (with Vivado on the PC)
# see the TCL in Section 5.1
```

### A.4 Vivado Programming (on the PC)

```tcl
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target
set dev [lindex [get_hw_devices] 0]
current_hw_device $dev
set_property PROGRAM.FILE {system.bit} $dev
program_hw_devices $dev
refresh_hw_device $dev
```

---

## Appendix B: File Checksums

### B.1 v8 Release Package (this version)

| File | Size | md5 |
|---|---|---|
| `BOOT.BIN` | 5,177,792 | `835b415252fe70d7b8522620578bda28` |
| `image.ub` | 17,870,984 | `d8685f5975a001ffd71e3eea0e7f11ee` |
| `system.bit` | 4,045,674 B | `7272de4272ca910779471c30b0d86584` |
| `system.xsa` | — | — |
| `BOOT.BIN` FSBL segment | 98,312 | — |

### B.2 Master Card / Master Image

| File | Size | md5 |
|---|---|---|
| `xvc_v12_sd.img.gz` | approx. 20 MB | to be filled in after the image is built |
| `xvc_v8.tar.gz` | approx. 19 MB | to be packed (see the release package) |

### B.3 Key Programs Inside image.ub (measured)

| Path | Size | md5 (first 12 chars) |
|---|---|---|
| `/usr/bin/oled_ip` | 66,960 B | `1c6600c46243` |
| `/usr/bin/i2cprobe` | 66,952 B | `6f507f6f0b7c` |
| `/etc/init.d/oled_ip` | 477 B | `675103d6a3ff` |
| `/etc/rc5.d/S98oled_ip` | 17 B | `91a3b77cbd8b` |
| `/usr/bin/xvcserver_g1` | 66,976 B | `d6728f300974` |
| `/usr/bin/xvcinfo` | 66,948 B | `55a4b7774036` |

### B.4 Historical Versions

| Version | BOOT.BIN md5 | image.ub md5 | Note |
|---|---|---|---|
| v6 | `d2ad0928` | `2b3af4ea` | 12 channels + 1 broadcast engine, no OLED |
| v7 | `835b4152` | `b57d3e61` | Added I2C EMIO (OLED hardware) |
| v8 | `835b4152` | `c8f379df` | OLED display program + i2cprobe |
| **v12** | `835b4152` | `d8685f59` | **Fixes TCP shift byte order (critical) + session race + status bits + lock leak + password + OLED ghosting** |

---

## Appendix E: TCK Speed and settck (v14)

The XVC client (Vivado) first negotiates the TCK period with `settck:`, **usually requesting 1 MHz or slower**.
Before v14 there were two critical problems here:

| # | Problem | Symptom |
|---|---|---|
| 1 | 4-byte period **not byte-swapped** | `period_ns` becomes an astronomical number → DIV clamps to 65535 → **TCK 0.001 MHz** (slower than a snail) |
| 2 | `tck_div` is computed but **never written to the hardware** | Always the 10 MHz set by `-d` at startup |
| 3 | `tck_div = g_min_div` overwrites unconditionally | A client requesting 1 MHz is still forced to 10 MHz → over a long cable it is **detected but quickly lost** |

### The v14 Rule

```
tck_div = ceil(requested period (ns) / 20)      // 100MHz / (2*DIV)
if (tck_div < g_min_div) tck_div = g_min_div;   // -d is only the "fastest limit"
wr(0x14, tck_div) before every shift            // this is what actually takes effect
settck echoes the **actual** period (big-endian 4 bytes)   // the client judges the real speed from it
```

### Changed Meaning of the `-d` Option

| Option | Old meaning | **New meaning** |
|---|---|---|
| `-d 5` | **Forces** 10 MHz (ignores the client) | **Fastest limit** of 10 MHz (the client may run slower) |

### Measurements

| Requested period | Echo | Actual TCK | Time for a 1000-bit shift |
|---|---|---|---|
| 100 ns | 100 ns | 10 MHz | 1.96 ms |
| 500 ns | 500 ns | 2 MHz | 2.36 ms |
| **1000 ns** | 1000 ns | **1 MHz** | 3.06 ms |
| 5000 ns | 5000 ns | 0.2 MHz | 6.99 ms |

**Recommendation on the Vivado side**: if a long cable (>50 cm) is still unstable, set Speed manually to 1 MHz or 500 kHz.

---

## Appendix D: Broadcast Mask and bcast_en (v13)

In the RTL, `bcmask == 0` is expanded to select-all, so **the mask alone cannot express "select no channel"**.
From v13 on, `CTRL.bit0 (bcast_en)` is used as the master switch:

```
follow[i] = bcast_en & bcmask_eff[i]
```

| Mask | bcast_en | Effect |
|---|---|---|
| `0x000` | 0 | **Takes over no channel** (all 12 ports can connect freely) |
| `0x004` | 1 | Takes over ch2 only |
| `0xFFF` | 1 | Takes over all 12 |

**Factory inspection points**:
1. In the Web UI, **clear all** 12 BC checkboxes → no channel should show the broadcast state on the screen, and all 12 ports must be connectable ✓
2. Tick ch2 only → ch2 is refused, the others connect ✓
3. Check that `devmem 0x43CD0000 32` is **0** when the mask is empty ✓

**Note**: the server **never** rewrites `bcast_en` (session start / exit / self-heal do not touch it);
it is maintained entirely by the Web UI (CGI `setbcmask`).

---

## Appendix C: Key v12 Fixes

### 🔴 C.1 TCP shift Completely Broken (critical)

The XVC 1.0 protocol specifies that the 4-byte bit count after `shift:` is in **network byte order (big-endian)**.
The original server code read it directly as host little-endian:

```c
read_full(fd, &len, 4);     // client sends 00 00 00 08
                            // read as 0x08000000 = 134,217,728
if (len > XVC_MAX_BITS) return 1;   // → disconnects immediately
```

**Consequence**: programming over TCP from Vivado / any XVC client **could never succeed**;
the connection was just reset without explanation. Earlier tests wrote registers directly with `devmem`,
so this went unnoticed.

**Fix**:

```c
uint32_t blen = 0;
read_full(fd, &blen, 4);
len = (int)(((blen & 0x000000FFu) << 24) | ((blen & 0x0000FF00u) <<  8) |
            ((blen & 0x00FF0000u) >>  8) | ((blen & 0xFF000000u) >> 24));
```

**Acceptance**: 13 ports × 6 bit widths (8/32/64/200/1000/8192) = **30/30 pass**

### C.2 Session Exit Race

After a client disconnects its child process has not yet exited, so when a new connection arrives
`port_has_session()` still returns true → it is rejected with `refuse: port X already has a session`.
Fix: retry up to 15×100ms = 1.5 seconds before refusing.

### C.3 Wrong Status Bits Read

The RTL `0x30` layout is `{22'd0, state[9:8], bits[7:2], stream_chunk, busy}`,
but the server read `bit[3:2]` (the low 2 bits of bits). When the low 2 bits of the remaining
bit count == 3 it misjudged the state as `S_BC` (occupied by broadcast) and refused the shift. Fix: use `>> 8`.

### C.4 Timeout Leaks the Bus Lock

The timeout branch of `do_shift_one()` returned -1 without a `bus_unlock()`,
so after a single timeout every subsequent shift deadlocked permanently.

### C.5 root Password Reset

`petalinux-build` regenerates `project-spec/configs/rootfs_config` and
restores `CONFIG_ADD_EXTRA_USERS` to the default `root:root`.
Fix: pin the password with `extrausers` in `petalinux-image-minimal.bbappend`.
**Note**: bitbake expands `$VAR`, so every `$` in the SHA-512 hash must be written as `\$`.

### C.6 OLED Ghosting / Flicker

The board's busybox **has no `pkill`**, so the old processes left behind by every deployment in the past could not be killed,
and eventually 16 `oled_ip` processes wrote to I2C simultaneously → ghosting.
Fix: cleanup with `kill -9 $(ps|grep|awk)` + differential refresh (write only the pages that changed) +
page-write retry + single-instance check.

---

## Revision History

| Version | Date | Changes | Author |
|---|---|---|---|
| 1.0 | 2026-11-05 | Initial version (Methods A/B/C + 17 inspection items) | XVC Project Team |
| 1.1 | 2026-11-04 | Updated to the v12 image; added Appendix C (root cause and fix for the 6 bugs) | XVC Project Team |
| 1.2 | 2026-11-04 | Inspection extended to **18 items** (automated test added); Section 7.2 changed to the 73-item test suite | XVC Project Team |

---

**End of document**
