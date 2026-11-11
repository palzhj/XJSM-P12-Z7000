# Rescue Without Removing the Card: Boot U-Boot over JTAG to Fix the SD

> Scenario: the board will not boot (`image.ub` on the SD is incompatible), but you do not want to / cannot remove the card.
> Prerequisite: the onboard **Digilent USB JTAG** is connected to the Zynq TAP and the board is powered.

---

## 1. Boot U-Boot (XSCT)

```bash
source /opt/Xilinx/Vivado/2022.2/settings64.sh
xsct xvc/tools/jtag_boot_rescue.tcl
```

The script does three things:
1. Reset the system;
2. Load `zynq_fsbl.elf` into OCM and run it (**completing DDR/clock initialization**);
3. Stop the FSBL, load `u-boot.elf` into DDR and run it.

On success the serial console shows:

```
U-Boot 2021.01 (Xilinx)
Zynq> 
```

## 2. Fix the card (two methods)

### Method A: `ums` — expose the SD card as a USB drive (most intuitive)

```text
Zynq> ums 0 mmc 0
```

- A USB drive appears on the PC (that is the SD card's FAT partition);
- Copy `image.ub` into it directly (or rename the good `image.ub.ok` back);
- After copying, press **Ctrl+C** on the serial console to exit `ums`;
- Run `reset`.

### Method B: `tftpboot` + `fatwrite` (when no USB device port is available)

Start a TFTP server on the PC (with the image directory as its root):

```bash
# pick either one
sudo apt install tftpd-hpa     # or
python3 -m pip install py3tftp && py3tftp -p 69 --directory xvc/out
```

Serial console:

```text
Zynq> setenv ipaddr 192.168.1.113
Zynq> setenv serverip 192.168.1.50
Zynq> tftpboot 0x02000000 image.ub
Zynq> mmc dev 0
Zynq> fatwrite mmc 0 0x02000000 image.ub <length(hex)>
Zynq> reset
```

`<length(hex)>` is the `Bytes transferred = 0x...` printed by `tftpboot`.

## 3. Verification

After the board reboots:

```bash
ping 192.168.1.113
python3 -c "import socket;s=socket.create_connection(('192.168.1.113',2543));s.sendall(b'getinfo:');print(s.recv(64))"
```

It should return `xvcServer_v1.0:4194304`.

## 4. Notes

| Item | Notes |
|---|---|
| JTAG cable | Must be the one connected to the **Zynq TAP** (Digilent), not the K7/A7 chain |
| hw_server | Port 3121 on this machine; can also be reused while Vivado Hardware Manager is open |
| FSBL source | `xvc/petalinux/xvc/images/linux/zynq_fsbl.elf` (227 KB) |
| U-Boot source | `u-boot.elf` in the same directory (7.2 MB) |
| Risk | Only the SD contents are changed, not the board hardware; on failure it can simply be run again |
