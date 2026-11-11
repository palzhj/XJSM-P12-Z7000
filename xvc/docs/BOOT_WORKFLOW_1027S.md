# 10.27 s Programming Workflow (currently working solution)

> Background: the PL of the AC7Z020 cannot be loaded by our XVC (XVC only drives the external K7/A7 chain).
> Therefore the FIFO bitstream must be loaded via **Digilent JTAG**, which requires stopping in U-Boot first.

## Steps

### ① Boot to U-Boot (xsdb, about 10 s)

```bash
source /opt/Xilinx/Vivado/2022.2/settings64.sh
xsdb xvc/out/tmp/ub.tcl
```

The script does: reset the system → load the FSBL (initializes DDR) → load U-Boot → run.

### ② Program the AC7Z020 PL with Vivado (about 5 s)

```tcl
open_hw_manager
connect_hw_server -url localhost:3121
open_hw_target [get_hw_targets */Digilent/210512180081]
set dev [lindex [get_hw_devices xc7z020*] 0]
set_property PROGRAM.FILE {.../out_g1/system_wrapper.bit} $dev
program_hw_devices $dev
```

(Wrapped in `xvc/out/tmp/plprog.tcl`)

### ③ Boot Linux from U-Boot

```tcl
# serial console (/dev/ttyUSB3)
run bootcmd
```

### ④ Start the streaming server

```bash
# board serial console
wget -q http://<host>:8015/xvcserver_stream2 -O /tmp/xv
chmod +x /tmp/xv
kill -9 $(pidof xvcserver)
/tmp/xv -a 0x43C00000 -d 5
```

The startup log should show:

```
PL_TAG=0xA7000000
FIFO_STATUS=0x00000080  tx_free=128 rx_used=0
```

### ⑤ Program (10.27 s)

```bash
./xvc/tools/program_and_log.sh <bitfile> 10 "note"
```

## Measured data

| Item | Value |
|---|---|
| Programming time | **10.27 s** (20 runs: 10.243 ~ 10.317, ±0.36%) |
| Success rate | 20/20 = 100% |
| TCK lower bound | 9.2 s (90% achieved) |
| USB cable baseline | 9.56 s |

## Why it cannot be "ready at power-on"

| Path | Status |
|---|---|
| Put the FIFO bitstream into BOOT.BIN | ❌ The packed image does not boot |
| Load the AC7Z020 PL via XVC | ❌ XVC only reaches the external chain |
| Via `/dev/fpga0` or fpga_manager | ❌ Kernel rejects (EINVAL) |
| Via Digilent JTAG | ✅ But requires stopping in U-Boot |

### Known facts about the BOOT.BIN packaging problem

| Item | Result |
|---|---|
| Extracted FSBL (from the stable version) | Byte-for-byte identical ✅ |
| Project U-Boot | Same md5 after rebuild (deterministic build) |
| New image size | 5,134,820 vs stable 5,137,208 (2,388 bytes difference) |
| Boot behavior | FSBL produces no serial output at all |

**To investigate**: the origin of the 2,388-byte difference.

### 2026-10-31 deep-dive results

1. `petalinux-build -x distclean` has no effect (sstate reuse); you must use **`-x mrproper`**;
2. After `mrproper` and a rebuild, `zynq_fsbl.elf` is back to **227,332 bytes** (normal);
3. But the **FSBL binary produced by `objcopy` is only 65,544 bytes**, while the bootable one in the archive is **98,312 bytes**;
4. The two already differ at offset `0x3C` — **this is a difference between two builds, not merely a sectioning issue**;
5. Packing with the extracted 98,312-byte FSBL (`BOOT_fifo2`, md5 `9f347104`):
   - the FSBL section in BOOT.BIN is **byte-for-byte identical** to the stable version
   - **but it still does not boot** → the problem is not the FSBL section itself, but other parts of the packaging (partition table / bitstream section)

**Conclusion**: A BOOT.BIN produced by the current PetaLinux toolchain will not boot, and the cause is not located.
In the short term, keep using the archived stable BOOT.BIN and load the FIFO/OLED bitstream at runtime via Digilent JTAG
(note: reloading the PL at runtime may break the PS-side AXI, requiring a reboot to recover).
