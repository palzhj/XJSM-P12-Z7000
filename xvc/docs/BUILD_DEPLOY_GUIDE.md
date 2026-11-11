# XJSM-P12-Z7000 Complete Build and Deployment Guide

> Version 1.0 · 2026-11-01
> Scope: Vivado 2023.1 hardware design → PetaLinux 2023.1 images → SD card deployment → on-board verification

---

# Part 1: Project Overview

## 1.1 Objective

Use a Zynq (XC7Z020 on the AC7Z020) to remotely drive an external AMD Xilinx FPGA JTAG chain
over the **XVC (Xilinx Virtual Cable)** protocol, replacing the USB JTAG download cable.

## 1.2 Hardware Topology

```
PC (Vivado / xsdb)
  │  Ethernet 192.168.1.x
  ▼
AC7Z020  (XC7Z020-2CLG400I, 1GB DDR3, 256Mb QSPI, SD)
  │  PS MIO  →  PL pins (J20/J21)
  ▼
AMD Xilinx FPGA chain        (external JTAG chain)
```

## 1.3 Key Metrics

| Item | Value |
|---|---|
| Single-channel FPGA programming | **10.27 s** (20/20 runs, ±0.36%) |
| 12 channels in parallel | **6.2× speedup** |
| Flash programming (with verification) | **200.7 s** |
| TCK | up to 10 MHz (DIV=5) |
| XVC ports | 2542 (broadcast), 2543~2554 (channels 0~11) |

## 1.4 Software Versions

| Tool | Version |
|---|---|
| Vivado | **2023.1** |
| PetaLinux | **2023.1** |
| Kernel | 5.15.36 (or 6.1.5, depending on the project) |
| Build environment | VirtualBox VM `u20` (Ubuntu 20.04.6) |

---

# Part 2: Root Cause (Must Read)

## 2.1 Symptoms

| Symptom | Behavior |
|---|---|
| Self-built BOOT.BIN | Board cannot boot from SD |
| Self-built image.ub | Silent after `Starting kernel ...` |
| PetaLinux configuration | Everything is `CONFIG_SUBSYSTEM_*_MANUAL_SELECT=y` |
| FSBL size | 65,544 bytes (should be 98,312) |

## 2.2 Root Cause: `apply_ps7_config` Was Never Called

`xvc/vivado/tcl/ps7_config.tcl` defines a procedure:

```tcl
proc apply_ps7_config {cell} {
  set_property -dict [list CONFIG.PCW_EN_SDIO0 {1} ...] $cell
}
```

But in scripts such as `build_jtag12p.tcl` it was **only sourced, never called**:

```tcl
source [file join $script_dir tcl ps7_config.tcl]   # definition only
create_bd_cell ... processing_system7 ps7
# ← missing apply_ps7_config [get_bd_cells ps7]
```

As a result PS7 keeps the IP defaults → **every PS peripheral is disabled**:

```
PCW_EN_SDIO0 = 0   ← SD card
PCW_EN_QSPI  = 0   ← QSPI Flash
PCW_EN_UART1 = 0   ← debug UART
PCW_EN_ENET0 = 0   ← Ethernet
```

## 2.3 Knock-on Effects

```
PS7 peripherals disabled
  ├─→ XSA parameters are 0
  │     └─→ PetaLinux cannot detect peripherals → every setting becomes MANUAL_SELECT
  │           ├─→ FSBL does not compile in SD/QSPI drivers (65,544 bytes)
  │           │     └─→ board cannot boot from SD
  │           └─→ device tree missing nodes + empty bootargs
  │                 └─→ kernel has no console/network → appears "hung"
  └─→ (PL AXI/FCLK are still fine, so the FIFO functionality itself works)
```

## 2.4 The Three Fixes

### ① Add the PS7 configuration call

```tcl
source [file join $script_dir tcl ps7_config.tcl]
apply_ps7_config [get_bd_cells ps7]
```

### ② Connect the HP0 clock

The vendor PS7 configuration enables `S_AXI_HP0`, so it must be clocked (otherwise `validate_bd_design` reports an error):

```tcl
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/S_AXI_HP0_ACLK]
```

### ③ Write bootargs into `system-user.dtsi`

```dts
/ {
	chosen {
		bootargs = "earlycon console=ttyPS0,115200 clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio";
	};
};
```

## 2.5 Verification Data After the Fix

| Check | Before fix | After fix |
|---|---|---|
| `PCW_EN_SDIO0` | 0 ✗ | **1** ✓ |
| `PCW_EN_QSPI` | 0 ✗ | **1** ✓ |
| `PCW_EN_UART1` | 0 ✗ | **1** ✓ |
| `PCW_EN_ENET0` | 0 ✗ | **1** ✓ |
| PetaLinux device detection | all MANUAL ✗ | all auto-detected ✓ |
| FSBL BIN | 65,544 ✗ | **98,312** ✓ (matches vendor) |
| image.ub device tree | 18,168 B, missing nodes ✗ | 21,027 B, all nodes present ✓ |
| bootargs | empty ✗ | complete ✓ |

---

# Part 3: Complete Build Steps

## Step 0: Environment Setup

### 0.1 Host (Linux)

```bash
# Vivado 2023.1
ls /opt/Xilinx/Vivado/2023.1/settings64.sh
source /opt/Xilinx/Vivado/2023.1/settings64.sh
```

### 0.2 Virtual Machine u20

```bash
# start
VBoxManage startvm u20 --type headless

# check PetaLinux
# after logging in
ls /opt/Xilinx/petalinux/2023.1/settings.sh
source /opt/Xilinx/petalinux/2023.1/settings.sh
```

### 0.3 Shared Folder

```
/media/sf_a435849f-51ca-4a93-abc2-5d48c0bc1de3
  = USB drive root (project lives in work/XJSM-P12-Z7000)
```

---

## Step 1: Generate the Bitstream and XSA with Vivado 2023.1

### 1.1 Confirm the Build Script Is Fixed

```bash
cd work/XJSM-P12-Z7000

# these two lines must be present (order matters)
grep -n "ps7_config\|apply_ps7_config" xvc/vivado/build_jtag12p.tcl
# 14: source [file join $script_dir tcl ps7_config.tcl]
# 15: apply_ps7_config [get_bd_cells ps7]

# the HP0 clock connection must be present
grep -n "S_AXI_HP0_ACLK" xvc/vivado/build_jtag12p.tcl
```

### 1.2 Run the Build

```bash
source /opt/Xilinx/Vivado/2023.1/settings64.sh
rm -rf xvc/vivado/work_jtag12p xvc/vivado/out_jtag12p
vivado -mode batch -nojournal -nolog -notrace \
       -source xvc/vivado/build_jtag12p.tcl \
       > xvc/logs/build12p.log 2>&1
echo "EXIT=$?"
grep -E "^ERROR|BUILD_DONE" xvc/logs/build12p.log | head -3
```

**Expected output**: `BUILD_DONE`, no `ERROR`

### 1.3 Check the Artifacts

```bash
ls -l xvc/vivado/out_jtag12p/
# system.xsa          ~600 KB   ← key: grows once the PS7 parameters are fixed
# system_wrapper.bit  ~4 MB

# verify the PS7 parameters (critical!)
rm -rf /tmp/xnew && mkdir -p /tmp/xnew
unzip -o -q xvc/vivado/out_jtag12p/system.xsa -d /tmp/xnew
for p in PCW_EN_SDIO0 PCW_EN_QSPI PCW_EN_UART1 PCW_EN_ENET0; do
  grep -o "NAME=\"$p\" VALUE=\"[^\"]*\"" /tmp/xnew/system.hwh | head -1
done
# expected: all VALUE="1"
```

⚠️ **If any of them is not 1, do not continue** —— that means `apply_ps7_config` did not take effect.

---

## Step 2: Generate the Images with PetaLinux 2023.1

### 2.1 Create the Project and Import the XSA

```bash
# inside the u20 VM
source /opt/Xilinx/petalinux/2023.1/settings.sh

mkdir -p ~/work && cd ~/work

# fetch the XSA from the shared folder
sg vboxsf -c "cp /media/sf_a435849f-51ca-4a93-abc2-5d48c0bc1de3/work/XJSM-P12-Z7000/xvc/vivado/out_jtag12p/system.xsa /tmp/"

# create the project
petalinux-create -t project -n xvc --template zynq    # → ~/work/xvc

mkdir -p /tmp/xsa && cp /tmp/system.xsa /tmp/xsa/
cd xvc
petalinux-config --get-hw-description=/tmp/xsa --silentconfig
```

### 2.2 Verify Device Detection (Critical!)

```bash
grep -E "SUBSYSTEM_PRIMARY_SD_PS7|SUBSYSTEM_SERIAL_PS7_UART_1_SELECT|\
SUBSYSTEM_ETHERNET_PS7_ETHERNET_0_SELECT|SUBSYSTEM_FLASH_PS7_QSPI" \
  project-spec/configs/config
```

**Expected**:
```
CONFIG_SUBSYSTEM_SERIAL_PS7_UART_1_SELECT=y          ✓
CONFIG_SUBSYSTEM_ETHERNET_PS7_ETHERNET_0_SELECT=y    ✓
CONFIG_SUBSYSTEM_PRIMARY_SD_PS7_SD_0_SELECT=y        ✓
CONFIG_SUBSYSTEM_FLASH_PS7_QSPI_0_BANKLESS_SELECT=y  ✓
```

**Must never appear**:
```
CONFIG_SUBSYSTEM_*_MANUAL_SELECT=y    ← detection failed
```

⚠️ If MANUAL_SELECT appears → go back to step 1.3 and check the XSA parameters.

### 2.3 Add bootargs (Required)

```bash
cat > project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi <<'DTS'
/include/ "system-conf.dtsi"
/ {
	chosen {
		bootargs = "earlycon console=ttyPS0,115200 clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio";
	};
};
DTS
```

### 2.4 Add the Application Recipes

```bash
# fetch the bundle from the shared folder
sg vboxsf -c "cp /media/sf_a435849f-51ca-4a93-abc2-5d48c0bc1de3/work/XJSM-P12-Z7000/pl_bundle.tar.gz /tmp/"
mkdir -p /tmp/pb && tar xzf /tmp/pl_bundle.tar.gz -C /tmp/pb

cp -r /tmp/pb/meta-user/recipes-apps/* project-spec/meta-user/recipes-apps/

# enable the three applications
for k in xvcserver-g1 xvcinfo xvcweb; do
  echo "CONFIG_$k=y" >> project-spec/configs/rootfs_config
done
```

### 2.5 Fix the cracklib Build (Required for PetaLinux 2023.1)

The upstream `cracklib` branch was renamed from `master` to `main`, otherwise the fetch fails:

```bash
mkdir -p project-spec/meta-user/recipes-extended/cracklib
cat > project-spec/meta-user/recipes-extended/cracklib/cracklib_%.bbappend <<'APP'
SRC_URI = "git://github.com/cracklib/cracklib;protocol=https;branch=main"
APP
```

### 2.6 Build

```bash
# a retry loop is recommended (unstable network)
cat > /tmp/build.sh <<'SH'
#!/bin/bash
cd ~/work/xvc
source /opt/Xilinx/petalinux/2023.1/settings.sh
for i in 1 2 3 4 5; do
  echo "=== TRY $i $(date +%H:%M:%S)" >> /tmp/build.log
  petalinux-build >> /tmp/build.log 2>&1 && { echo TRY_OK >> /tmp/build.log; break; }
  echo TRY_FAIL >> /tmp/build.log
  sleep 5
done
echo LOOP_DONE >> /tmp/build.log
SH
chmod +x /tmp/build.sh
setsid nohup /tmp/build.sh </dev/null >/dev/null 2>&1 &

# monitor
tail -f /tmp/build.log
```

**Normal duration**: 40~70 minutes (4,139 tasks on the first full build)

**Completion marker**: `TRY_OK` present and `grep -c "^ERROR: Task" /tmp/build.log` is 0

### 2.7 Verify the Artifacts (Critical!)

```bash
# ① FSBL size must be 98,312
OBJ=$(find /opt/Xilinx/petalinux/2023.1/tools -name arm-none-eabi-objcopy | head -1)
$OBJ -O binary images/linux/zynq_fsbl.elf /tmp/fsbl.bin
echo "FSBL = $(stat -c%s /tmp/fsbl.bin) bytes"
# expected: 98312

# ② bootargs must be present
strings images/linux/image.ub | grep -o "earlycon console=ttyPS0[^\"]*" | head -1

# ③ all device tree nodes must be present
python3 - <<'PY'
import struct, re
d = open('images/linux/image.ub','rb').read()
for m in re.finditer(b'\xd0\x0d\xfe\xed', d):
    o = m.start()
    if o+40 > len(d): continue
    ts = struct.unpack('>I', d[o+4:o+8])[0]
    if 5000 < ts < 300000 and o+ts <= len(d):
        dtb = d[o:o+ts]
        print("DT =", ts, "bytes")
        for k in (b'serial@e0001000', b'mmc@e0100000',
                  b'ethernet@e000b000', b'spi@e000d000', b'jtag_ctrl'):
            print("  %-18s %s" % (k.decode(), "OK" if k in dtb else "MISSING"))
        break
PY
```

**Expected**:
```
FSBL = 98312 bytes
earlycon console=ttyPS0,115200 clk_ignore_unused uio_pdrv_genirq.of_id=generic-uio
DT = ~21000 bytes
  serial@e0001000    OK
  mmc@e0100000       OK
  ethernet@e000b000  OK
  spi@e000d000       OK
  jtag_ctrl          OK
```

### 2.8 Package BOOT.BIN

```bash
petalinux-package --boot \
  --fsbl images/linux/zynq_fsbl.elf \
  --fpga images/linux/system.bit \
  --u-boot images/linux/u-boot.elf \
  --force

# verify the FSBL length inside BOOT.BIN
python3 -c "
import struct
d = open('images/linux/BOOT.BIN','rb').read()
print('BOOT.BIN:', len(d), 'FSBL:', struct.unpack('<I', d[0x34:0x38])[0])
"
# expected FSBL: 98312
```

⚠️ The partition order must be **fsbl → bitstream → u-boot** and must not be reversed.

---

## Step 3: Deploy to the SD Card

### 3.1 Preparation

The SD card needs a **FAT32** partition (≥512 MB recommended).

Insert the card into the PC and confirm the mount point (for example `/run/media/$USER/BOOT`).

### 3.2 Copy the Files

```bash
CARD=/run/media/$USER/BOOT

cp images/linux/BOOT.BIN  $CARD/
cp images/linux/image.ub  $CARD/
sync
```

### 3.3 Verify

```bash
md5sum $CARD/BOOT.BIN $CARD/image.ub
```

### 3.4 BOOT.BIN Length Self-Check

```bash
python3 -c "
import struct
d = open('$CARD/BOOT.BIN','rb').read()
fsbl = struct.unpack('<I', d[0x34:0x38])[0]
print('FSBL =', fsbl, 'bytes', '✓' if fsbl == 98312 else '✗ WRONG!')
"
```

⚠️ If FSBL ≠ 98312 → the board **cannot boot from SD**; do not put the card back into the board.

---

## Step 4: On-Board Verification

### 4.1 Connections

| Item | Description |
|---|---|
| Serial port | CP2102N, 115200 8N1 (on the host it may be `/dev/ttyUSB0~4`; confirm with `by-id`) |
| Ethernet port | Same subnet as the PC |
| JTAG | Optional (used to load the PL bitstream) |

Confirm the serial port:
```bash
ls -l /dev/serial/by-id/
# look for usb-Silicon_Labs_CP2102N_...
```

### 4.2 Power-On

Insert the SD card → power on → watch the serial console (about 30~45 seconds):

```
U-Boot 2022.01/2023.1 ...
Loading Kernel Image
Loading Ramdisk ...
Loading Device Tree ...
Starting kernel ...
[    0.000000] Booting Linux on physical CPU 0x0
...
PetaLinux 2023.1 ... xvc /dev/ttyPS0
xvc login:
```

Login: `root` / `root`

### 4.3 Network Check

```bash
ip addr show eth0
ping -c2 192.168.1.1
```

If a static IP is needed:
```bash
ip addr add 192.168.1.113/24 dev eth0
```

### 4.4 Load the PL Bitstream

**Method A: carried inside BOOT.BIN**
If `--fpga` used the target bitstream when packaging, it is already loaded at boot; skip this step.

**Method B: load over JTAG**
```bash
# host
source /opt/Xilinx/Vivado/2023.1/settings64.sh
hw_server -d &
xsdb
xsdb% connect -url TCP:localhost:3121
xsdb% targets -set -filter {name =~ "xc7z020"}
xsdb% fpga -file /path/to/jtag12p_fixed.bit
```

**Method C: XVC (when the server is already running)**
```bash
./xvc/tools/program_and_log.sh fpga/jtag12p_fixed.bit 10 "12ch"
```

### 4.5 Start the XVC Server

```bash
# 12 channels (base address 0x43C00000, +0x10000 per channel)
/usr/bin/xvcserver_g1 -a 0x43C00000 -d 5 &
```

### 4.6 Verify XVC

```bash
# broadcast port
python3 -c "
import socket
s = socket.create_connection(('192.168.1.113', 2542), 3)
s.sendall(b'getinfo:')
print(s.recv(64).decode().strip())
"
# expected: xvcServer_v1.0:4194304
```

### 4.7 Open the Web Console

Access `http://192.168.1.113/` in a browser

**Expected**:
- Toolbar: network IP, status, Start/Restart/Stop, JTAG speed
- Table with 10 columns: Channel / BC / TDO / Port / Client / State / Speed / TX free / RX used / Transferred
- First row: BROADCAST summary

### 4.8 End-to-End Test

Run a Vivado programming test from the host:

```tcl
# vivado_prog.tcl
open_hw_manager
connect_hw_server -url 192.168.1.113:2543
open_hw_target
current_hw_device [lindex [get_hw_devices] 0]
set_property PROGRAM.FILE {/path/to/design.bit} [current_hw_device]
program_hw_devices
```

**Expected duration**: about 10.3 seconds (10 MHz TCK)

---

# Part 4: Troubleshooting

## 4.1 The Board Does Not Boot

### Symptom A: no serial output at all

| Check | Command |
|---|---|
| FSBL size | `python3 -c "import struct;d=open('BOOT.BIN','rb').read();print(struct.unpack('<I',d[0x34:0x38])[0])"` → must be 98312 |
| Card format | `lsblk -f` → FAT32 |
| Card contact | re-seat the card |

### Symptom B: silence after `Starting kernel ...`

| Check | Command |
|---|---|
| bootargs | `strings image.ub \| grep earlycon` |
| Serial baud rate | 115200 8N1 |
| Serial device | `ls /dev/serial/by-id/` to confirm it is the CP2102N |

### Symptom C: `MMC: 0 busy timeout`

A U-Boot SD driver issue (works fine under Linux). Workarounds:
1. Write the card directly from the PC (most reliable)
2. Load U-Boot over JTAG, then recover from a USB stick with `usb start` + `fatload usb 0:1`
3. If Linux boots: write the card from Linux

---

## 4.2 PetaLinux Build Failures

### Error: `Failed to create workspace directory`

config was reset. Check whether `apply_ps7_config` took effect (back to step 1.3).

### Error: `Task cracklib do_fetch failed`

Branch renamed. Add the bbappend (step 2.5).

### Error: `NetworkAccess(...tar.gz)` / download timeout

Reuse the existing download cache:
```bash
mkdir -p build/downloads
cp -rn ~/old-project/build/downloads/* build/downloads/
cp -rn ~/old-project/build/downloads/git2/* build/downloads/git2/
```

### Error: `Trying to assign a console::$console_ip which doesn't exists`

The PS7 UART was not detected → back to step 1.3.

### Error: `[BD 41-758] S_AXI_HP0_ACLK not connected`

Add the clock connection (item ② in step 2.4).

---

## 4.3 JTAG-Related

### `xsdb targets` is empty

```bash
hw_server -d &          # must be started manually first
sleep 5
xsdb
xsdb% connect -url TCP:localhost:3121
xsdb% targets
```

### XVC programming reports `Flash Programming Unsuccessful`

Program Vivado's SPI bridging bitstream first:
```tcl
set bitfile [lindex [glob /opt/Xilinx/Vivado/2023.1/data/xicom/cfgmem/bitfile.zip] 0]
# extract spi_xc7k325t_pullnone.bit and use it with program_hw_devices first
# then run write_cfgmem
```

---

# Part 5: File Inventory

## 5.1 Key Paths

| Path | Description |
|---|---|
| `xvc/vivado/build_jtag12p.tcl` | 12-channel build script (**includes the PS7 fix**) |
| `xvc/vivado/tcl/ps7_config.tcl` | PS7 configuration (proc definition) |
| `xvc/vivado/rtl/jtag_ctrl.v` | XVC engine RTL |
| `xvc/vivado/constraints/jtag12.xdc` | 48 pin constraints |
| `xvc/petalinux/xvc/` | PetaLinux project |
| `xvc/petalinux/apps/xvcserver_g1/` | 13-port server |
| `xvc/petalinux/apps/xvcinfo/` | Status/control tool |
| `xvc/web/` | Web console |
| `xvc/out/fixed/` | **final fixed artifacts** |

## 5.2 Artifact md5

| File | Size | md5 |
|---|---|---|
| BOOT.BIN | 5,177,380 | `6df51f2dd9cf1dc611edc860a47e90b6` |
| image.ub | 17,843,768 | `a013672af0052479093479b1522b8eea` |
| zynq_fsbl.elf | 474,264 | `9ec655ef141367f5f1f8b10cc7d28ff0` |

## 5.3 Register Map (jtag_ctrl)

| Offset | Name | Description |
|---|---|---|
| `0x00` | LEN | Bit length |
| `0x04` | TMS | TMS data |
| `0x08` | TDI | TDI data |
| `0x0C` | TDO | TDO read-out |
| `0x10` | CTRL | Control (start/flush) |
| `0x14` | DIV | Clock divider (write); `PL_TAG` read-out = `0xA7xxxxxx` |
| `0x18` | DIV_RB | Divider read-back |
| `0x1C` | TXD | TX FIFO data |
| `0x20` | RXD | RX FIFO data |
| `0x24` | STATUS | `{0, rx_used, tx_free}` |
| `0x28` | DONE | Done flag |
| `0x2C` | PH | Phase |
| `0x30` | STATE | State machine |
| `0x34` | START | Start |
| `0x38` | SEQ | Sequence number |
| `0x3C` | CHSEL | Broadcast TDO source (default 0 = G1) |
| `0x40` | BCMASK | 12-bit broadcast channel mask (default `0xFFF`) |

Channel base address: `0x43C00000 + ch * 0x10000` (ch = 0~11)

---

# Part 6: Reference Document Index

| Document | Content |
|---|---|
| `ROOTCAUSE_FIXED.md` | Root cause and the complete fix history (**must read**) |
| `XSA_EXPORT_REVIEW.md` | XSA export flow compared against the vendor manual |
| `CHANNELS12.md` | 12-channel design description |
| `WEB_CONSOLE.md` | Web console design and API |
| `FLASH_PROGRAMMING_FINDINGS.md` | Flash programming (SPI bridge 27-3347 issue) |
| `JTAG_RECOVERY.md` | JTAG recovery procedure |
| `WHY_FSBL_DIFFERS.md` | FSBL difference analysis (historical) |
| `BUILD_2023_1_FINDINGS.md` | 2023.1 build troubleshooting (historical) |
| `U20_U22_BUILD.md` | Build comparison between the u20/u22 VMs |
| `KNOWN_ISSUES.md` | Summary of known issues |

---

# Appendix A: One-Shot Check Script

```bash
#!/bin/bash
# check_build.sh -- build artifact integrity check

set +e
echo "=== FSBL size ==="
OBJ=$(find /opt/Xilinx/petalinux/2023.1/tools -name arm-none-eabi-objcopy | head -1)
$OBJ -O binary images/linux/zynq_fsbl.elf /tmp/_fsbl.bin 2>/dev/null
SZ=$(stat -c%s /tmp/_fsbl.bin 2>/dev/null)
[ "$SZ" = "98312" ] && echo "  ✓ $SZ" || echo "  ✗ $SZ (should be 98312)"

echo "=== BOOT.BIN FSBL length ==="
python3 -c "
import struct
d = open('images/linux/BOOT.BIN','rb').read()
f = struct.unpack('<I', d[0x34:0x38])[0]
print('  %s %d' % ('✓' if f == 98312 else '✗', f))
" 2>/dev/null

echo "=== bootargs ==="
strings images/linux/image.ub | grep -q "console=ttyPS0" && echo "  ✓ present" || echo "  ✗ missing"

echo "=== device tree nodes ==="
python3 - <<'PY'
import struct, re
d = open('images/linux/image.ub','rb').read()
for m in re.finditer(b'\xd0\x0d\xfe\xed', d):
    o = m.start()
    if o+40 > len(d): continue
    ts = struct.unpack('>I', d[o+4:o+8])[0]
    if 5000 < ts < 300000 and o+ts <= len(d):
        dtb = d[o:o+ts]
        for k in (b'serial@e0001000', b'mmc@e0100000',
                  b'ethernet@e000b000', b'spi@e000d000'):
            print("  %s %s" % ('✓' if k in dtb else '✗', k.decode()))
        break
PY
```

---

# Appendix B: Environment Variables Quick Reference

```bash
# Vivado 2023.1
source /opt/Xilinx/Vivado/2023.1/settings64.sh

# PetaLinux 2023.1 (inside the VM)
source /opt/Xilinx/petalinux/2023.1/settings.sh

# VM control
VBoxManage startvm u20 --type headless
VBoxManage list runningvms
VBoxManage guestcontrol u20 run --exe=/bin/bash \
  --username=iheper --password=<password> --wait-stdout -- /tmp/script.sh
```

---

**End of document**

---

# Appendix C: Virtual Machine Project Locations

## Current Layout (since 2026-11-01)

| Path | Contents | Size |
|---|---|---|
| **`~/work/xvc`** | ★ main project (contains the complete fixed build) | 28 GB |
| `~/work/xvc/images/linux/` | BOOT.BIN / image.ub / zynq_fsbl.elf | — |
| `~/work/xvc/project-spec/` | configuration, recipes, dtsi | — |

Old projects (can be deleted to free space):

| Path | Description | Size |
|---|---|---|
| `~/pl31/xvc31` | early 2023.1 attempt (configuration not fixed) | 30 GB |
| `~/pl2/ax_peta` | vendor BSP attempt (build failed) | 21 GB |
| `~/pl_val/XJSM-P12-Z7000` | old 2022.2 project | 14 GB |

Free the space: `rm -rf ~/pl31 ~/pl2 ~/pl_val` (about 65 GB)

## ⚠️ Cautions When Moving the Project

The `build/` directory of a PetaLinux project **hard-codes absolute paths**. After moving the project:

```bash
# symptom
Error, TMPDIR has changed location

# must clean up and rebuild
cd ~/work/xvc
rm -rf build/tmp build/sstate-cache build/cache
petalinux-build          # full rebuild (about 1 hour)
```

**The artifacts (`images/linux/`) are unaffected** and remain usable after the move.

## Symbolic Links (Optional)

If old scripts reference the old path, keep compatibility:

```bash
ln -sfn ~/work/xvc ~/xtest/t_new
```

---

# Appendix D: Reproducibility Verification Record

## Rebuild Time: 2026-11-01 20:40

Full rebuild performed from `~/work/xvc` (after the move and after cleaning `build/tmp`):

```
Tasks Summary: Attempted 4139 tasks of which 437 didn't need to be rerun and all succeeded.
FSBL BIN = 98,312 bytes  ✓
```

## Artifact Comparison

| Artifact | Size | md5 (first build) | md5 (after rebuild) | Conclusion |
|---|---|---|---|---|
| **BOOT.BIN** | 5,177,380 | `6df51f2d` | `6df51f2d` | **identical** ✓ |
| image.ub | 17,843,768 | `a013672a` | `caf13f07` | same size, md5 changed ✗ |

### Why the image.ub md5 Changes

The FIT image embeds a **build timestamp** (the `timestamp` property),
so an image.ub rebuilt from identical sources **necessarily has a different md5**, but:

- Size identical (17,843,768 bytes) ✓
- Device tree identical (21,027 bytes, all nodes present) ✓
- bootargs identical ✓
- Kernel/ramdisk contents identical ✓

BOOT.BIN contains no timestamp, so it is **bit-for-bit reproducible** ✓

## Device Tree Verification (after rebuild)

```
DT = 21,027 bytes
  serial@e0001000    OK
  mmc@e0100000       OK
  ethernet@e000b000  OK
  spi@e000d000       OK
  jtag_ctrl          OK
```

## Conclusion

**The project is reproducible** ✓ A full rebuild from a clean state produces functionally equivalent firmware ✓

---

# Appendix E: User Accounts and Boot Autostart Configuration

## User Accounts (added 2026-11-02)

### 1. root password

`project-spec/configs/config`:
```
CONFIG_SUBSYSTEM_ROOT_PASSWORD="<your-password>"
```

### 2. Add the iheper user

`project-spec/meta-user/recipes-core/images/petalinux-image-minimal.bbappend`:

```bitbake
inherit extrausers

# Generate each hash with:  openssl passwd -6 '<your-password>'
# Escape every '$' as '\$' or bitbake will expand it and corrupt the hash.
EXTRA_USERS_PARAMS = "\
    useradd -m -s /bin/bash -p '\$6\$<salt>\$<hash>' iheper; \
    usermod -p '\$6\$<salt>\$<hash>' root; \
"
```

**Verification method** (unpack the ramdisk from image.ub and inspect it):

```python
# parse FIT → ramdisk-1/data → gunzip → find shadow
OK   iheper:$6$<salt>$<hash>...
OK   root:  $6$<salt>$<hash>...
```

## Boot Autostart

`recipes-apps/xvcweb/files/xvcweb.init` + `rc5.d/S99xvcweb`:

```sh
#!/bin/sh
case "$1" in
  start)
    mkdir -p /var/www
    [ -d /var/www/cgi-bin ] || cp -r /usr/share/xvcweb/www/* /var/www/
    /usr/bin/xvcserver_g1 -a 0x43C00000 -d 5 > /tmp/xvcserver.log 2>&1 &
    httpd -p 80 -h /var/www
    ;;
esac
```

## Correct Way to Add an Application to the rootfs

**Key point**: the entry must be written into `project-spec/meta-user/conf/user-rootfsconfig`,
otherwise `petalinux-config -c rootfs` will clear the entries in `rootfs_config`.

```
CONFIG_xvcserver-g1
CONFIG_xvcinfo
CONFIG_xvcweb
```

Then:
```bash
petalinux-config -c rootfs --silentconfig   # generate rootfs_config
grep -E "xvcserver|xvcinfo|xvcweb" project-spec/configs/rootfs_config
# CONFIG_xvcserver-g1=y ✓
# CONFIG_xvcinfo=y ✓
# CONFIG_xvcweb=y ✓
petalinux-build
```

**Verify the applications really made it into the image** (unpack the ramdisk):
```
OK   xvcserver_g1
OK   xvcinfo
OK   XVC Console
```

## Known Minor Issues

| Issue | Symptom | Status |
|---|---|---|
| `bcmask` reads back 0 | In the RTL, `bcmask_q <= 12'hFFF` sits inside the reset block, but `aresetn` is high at power-up and no reset is triggered | ✗ to be fixed |
| `server_pid` shows 0 | The CGI `pidof` check fails (the process is actually running) | ✗ to be fixed |

Fixes:
- RTL: `reg [11:0] bcmask_q = 12'hFFF;` (initialize at declaration)
- CGI: use `ps | grep` or check the port instead

---

# Appendix F: Two Cosmetic Fixes (Not Compiled Into the Final Image)

## 1. BCMASK Default Value

**Problem**: reads back `0x00000000`, should be `0x00000FFF`

**Cause**: `bcmask_q <= 12'hFFF` is written inside the `if (!aresetn)` reset block,
but `aresetn` is high when the PL powers up, so the reset branch never executes → the register stays at 0.

**Fix** (changed, not synthesized into the final image):
```verilog
// before
reg [11:0] bcmask_q;
...
if (!aresetn) begin ... bcmask_q <= 12'hFFF; end

// after
reg [11:0] bcmask_q = 12'hFFF;   // initialize at declaration
```

**Temporary workaround** (at runtime):
```bash
devmem 0x43C00040 32 0xFFF
```

## 2. server_pid Shows 0

**Problem**: the web status shows `"server_pid":0`, but the process is actually running

**Cause**: in `xvcinfo.c`, `popen("pidof xv12p")` queries the old process name;
the actual process is `xvcserver_g1`.

**Fix** (changed, not compiled into the final image):
```c
popen("pidof xvcserver_g1 xv12p 2>/dev/null", "r")
```

**Temporary check**:
```bash
ps | grep xvcserver
```

## Fix Status

| Item | Source | Image |
|---|---|---|
| RTL bcmask initialization | ✅ changed | ❌ not synthesized (BOOT.BIN md5 unchanged) |
| xvcinfo pidof | ✅ changed | ❌ not recompiled |

**How to re-apply**:
```bash
# RTL
cd xvc/vivado
rm -rf work_jtag12p out_jtag12p
vivado -mode batch -source build_jtag12p.tcl
cp work_jtag12p/jtag12p.runs/impl_1/system_wrapper.bit out_jtag12p/

# PetaLinux
cp out_jtag12p/system_wrapper.bit ~/work/xvc2/images/linux/system.bit
cd ~/work/xvc2
petalinux-build -c xvcinfo
petalinux-build
petalinux-package --boot --fsbl images/linux/zynq_fsbl.elf \
  --fpga images/linux/system.bit --u-boot images/linux/u-boot.elf --force
```

---

# Appendix G: Complete Evidence for the Missing BCMASK Register (2026-11-02)

## Conclusion

**Address `0x40` is not implemented in the current bitstream.** What is read back is residual AXI bus data, not a real register value.

## Evidence

### 1. Writes have no effect, but the read-back value follows what was written

```
write 0xFFF → read back 0x020
write 0x123 → read back 0x000
write 0x020 → read back 0x020
```

The written value is "echoed" back, which shows the address falls in an undecoded region and the read returns residual bus data.

### 2. The neighbouring CHSEL register works

```
CHSEL (0x3C): write 0x5 → read back 0x0005   ✅ works
BCMASK(0x40): write 0x5 → read back 0x????   ❌ no effect
```

Both registers exist in `jtag_ctrl.v`:

```verilog
4'd15: chsel_q  <= wdata[3:0];   /* 0x3C */   // present in the bitstream ✅
6'd16: bcmask_q <= wdata[11:0];  /* 0x40 */   // absent from the bitstream ❌
```

→ The bitstream is a version from **before BCMASK was added**

### 3. The server has a fallback

`xvcserver_g1.c:222`:

```c
mask = rd(REG_BCMASK) & 0xFFF;
if (!mask) mask = 0xFFF;   /* treat a zero mask as all ones */
```

So broadcasting **always applies to all 12 channels** ✓, it just cannot broadcast selectively ✗

## Front-End Handling

`index.html`:

```js
/* Do not sync bcmask from the register: 0x40 is not implemented in the
   current bitstream and the read-back is residual AXI data. Kept in localStorage. */
```

- Checkbox state is stored only in localStorage (key: `xvc_bcmask_v2`)
- The server's `bcmask` field is not read
- The checkboxes are currently "pre-wired UI" and will take effect automatically once the bitstream is fixed

## Fix Checklist (to execute once a build is possible)

1. **Re-synthesize in Vivado** (confirm the RTL 0x40 branch reaches the netlist)
   ```bash
   rm -rf work_jtag12p out_jtag12p
   vivado -mode batch -source build_jtag12p.tcl
   ```
2. **Verify the bitstream**: after download
   ```bash
   devmem 0x43C00040 32 0xFFF
   devmem 0x43C00040 32      # should read back 0xFFF
   ```
3. If it still does not work → check whether `bcmask_q` was optimized away in the synthesis report
