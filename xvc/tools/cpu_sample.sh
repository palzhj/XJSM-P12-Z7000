#!/bin/sh
# cpu_sample.sh - log system CPU jiffies and the XVC server's own CPU jiffies.
#
#   ./cpu_sample.sh [outfile] [samples]
#
# One line every 0.5 s:  epoch  total_jiffies  idle_jiffies  srv_utime  srv_stime
# /proc/stat's first line is "cpu user nice system idle iowait irq softirq steal",
# so total = sum of all and idle = idle+iowait.

OUT=${1:-/var/tmp/cpu.csv}
N=${2:-600}

PID=$(pidof xvcchunk 2>/dev/null)
[ -z "$PID" ] && PID=$(pidof xvcserver_g1 2>/dev/null)

: > "$OUT"
i=0
while [ "$i" -lt "$N" ]; do
    set -- $(head -1 /proc/stat)
    u=$2; n=$3; s=$4; id=$5; io=$6; irq=$7; si=$8; st=$9
    tot=$((u + n + s + id + io + irq + si + st))
    idle=$((id + io))
    su=0; ss=0
    if [ -n "$PID" ] && [ -r "/proc/$PID/stat" ]; then
        su=$(awk '{print $14}' "/proc/$PID/stat" 2>/dev/null)
        ss=$(awk '{print $15}' "/proc/$PID/stat" 2>/dev/null)
    fi
    echo "$(date +%s) $tot $idle ${su:-0} ${ss:-0}" >> "$OUT"
    sleep 0.5
    i=$((i + 1))
done
echo "DONE $(wc -l < "$OUT") lines"
