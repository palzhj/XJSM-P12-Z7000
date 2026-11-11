#!/bin/bash
# Run one XVC programming pass and log the elapsed time to xvc/logs/program_timing.csv
# Usage: ./program_and_log.sh [bitfile] [tck_mhz] [note]
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIT="${1:-$ROOT/test_bits/top-with-auto-neg.bit}"
TCK="${2:-10}"
NOTE="${3:-}"
LOG="$ROOT/xvc/logs/program_timing.csv"
[ -f "$LOG" ] || echo "timestamp,method,pl_rev,tck_mhz,engine,bits,result,duration_ms,note" > "$LOG"

source /opt/Xilinx/Vivado/2022.2/settings64.sh >/dev/null 2>&1
export HOME="$ROOT/xvc/out/vivado_home"
OUT=$(cd "$ROOT" && vivado -mode batch -nojournal -nolog -notrace \
      -source xvc/tools/vivado_program_retry.tcl 2>&1)

MS=$(echo "$OUT" | grep -oP 'PROGRAM_OK in \K[0-9]+' | head -1)
if [ -n "$MS" ]; then RESULT=OK; else RESULT=FAIL; MS=0; fi
BITS=$(stat -c %s "$BIT")
BITS=$(( BITS * 8 ))
TS=$(date +%Y-%m-%dT%H:%M:%S)
REV=$(echo "$OUT" | grep -oP 'PL_TAG=0x\K..' | head -1)
echo "$TS,xvc-2543,${REV:-?},$TCK,32bit,$BITS,$RESULT,$MS,\"$NOTE\"" >> "$LOG"
echo "$RESULT duration=${MS}ms  ($LOG)"
