#!/bin/bash
# Safe board flashing: download to /tmp -> verify md5 -> then write to SD
# Usage: flash_board.sh <host> <bootbin> <imageub>
HOST="${1:-192.168.1.113}"
BOOT="${2:-xvc/out/petalinux/BOOT.BIN}"
IMG="${3:-xvc/out/petalinux/image.ub}"
SD=/run/media/mmcblk0p1
md5() { md5sum "$1" | awk '{print $1}'; }

echo "== Checking SD free space"
FREE=$(ssh_serial df 2>/dev/null)
for f in "$BOOT" "$IMG"; do
    SRC=$(md5 "$f")
    NAME=$(basename "$f")
    echo "== Downloading $NAME"
    ./xvc/tools/serial_cmd.py "wget -q http://192.168.1.50:8001/$NAME -O /tmp/$NAME" 12 >/dev/null
    GOT=$(./xvc/tools/serial_cmd.py "md5sum /tmp/$NAME" 4 | grep -oE "[0-9a-f]{32}" | head -1)
    echo "   host=$SRC board=$GOT"
    if [ "$SRC" != "$GOT" ]; then echo "!! $NAME checksum mismatch, aborting"; exit 1; fi
    ./xvc/tools/serial_cmd.py "cp /tmp/$NAME $SD/$NAME && sync && md5sum $SD/$NAME" 6 | grep -oE "[0-9a-f]{32}" | head -1 | sed "s/^/   written: /"
done
echo "== Done, please reboot the board"
