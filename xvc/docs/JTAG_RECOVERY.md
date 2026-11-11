# JTAG Rescue Procedure (when the board will not boot)

> Verified working on 2026-10-31

## Key prerequisite: start hw_server manually first

**When xsdb starts hw_server itself, no target is visible** (hit this pitfall several times).
Start it manually first, then connect with `connect -url`:

```bash
source /opt/Xilinx/Vivado/2022.2/settings64.sh
hw_server -d &          # start manually
sleep 5
ss -tlnp | grep 3121    # confirm it is listening
```

## Verify the target

```bash
xsdb -eval 'connect -url TCP:localhost:3121; targets'
# you should see: APU / ARM Cortex-A9 #0 / #1 / xc7z020 / ...
```

## Load FSBL + U-Boot

```tcl
connect -url TCP:localhost:3121
after 1000
targets -set -filter {name =~ "APU"}
catch { stop }
after 500
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
catch { stop }
catch { rst -system }
after 3000
targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}
dow <project>/xvc/petalinux/xvc/images/linux/zynq_fsbl.elf
con
after 3000
catch { stop }
dow <project>/xvc/petalinux/xvc/images/linux/u-boot.elf
con
```

On success the serial console (`/dev/ttyUSB3`, 115200) shows `Zynq>`.

## What to do in U-Boot

```bash
# fix the card (if the SD is readable)
fatload mmc 0:1 0x10000000 image.ub.ok
fatwrite mmc 0:1 0x10000000 image.ub $filesize

# or boot straight from DDR (bypassing the SD)
bootm 0x10000000
```

## Load the image into DDR (when the SD is unreadable)

```bash
xsdb -eval 'connect -url TCP:localhost:3121; \
  targets -set -filter {name =~ "ARM Cortex-A9 MPCore #0"}; \
  dow -data <image.ub> 0x10000000'
# 29 MB takes about 84 seconds
```

Then in U-Boot: `bootm 0x10000000`

## Measured log (2026-10-31)

| Step | Result |
|---|---|
| Manual hw_server + xsdb | ✅ Target visible |
| Load FSBL + U-Boot | ✅ Reaches `Zynq>` |
| `mmc dev 0` / `mmc info` | ❌ `MMC: 0 busy timeout` (SD controller failure) |
| `ping` / `dhcp` | ❌ ARP timeout (link down) |
| Load image.ub into DDR over JTAG | ✅ 84 seconds, FIT verification passes |
| `bootm 0x10000000` | ⚠️ Hangs after `Starting kernel ...` |

## Conclusion

The root cause of the board not booting is that **the SD card controller cannot read the card** (`sdhci_set_clock: Timeout to wait cmd & data inhibit`).
Reseating the card does not help → the card must be replaced or the socket checked.

JTAG can get as far as U-Boot, but with no usable storage or network, the system recovery cannot be completed.
