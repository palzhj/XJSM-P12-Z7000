# Bench power setup (N6705C @ 192.168.1.88)

Recorded 2026-10-29. Keep this in sync with the bench — it is the only place the
channel-to-board mapping is written down.

## Instrument

| Field | Value |
|---|---|
| Model | Keysight N6705C DC Power Analyzer |
| Serial | `MY56001992` |
| Firmware | `E.01.06.2838` |
| Options | none (`*OPT?` → `0`) |
| Addresses | SCPI socket `192.168.1.88:5025`, web UI `192.168.1.88:80` |
| Host NIC | `enp90s0` = `192.168.1.50/24` (also `192.168.10.10/24`) |

Access via [n6705.py](n6705.py) (raw socket, no pyvisa on this host):

```bash
python3 tools/n6705.py status          # snapshot all 4 channels
python3 tools/n6705.py log 30 0.5      # 30 s @ 2 Hz -> CSV
```

`SYST:CHAN:CAT?` and `FUNC?` are unsupported on this firmware: an unsupported
query returns *nothing* (socket timeout), so always reconnect per query and never
read a missing reply as "0".

⚠ **Channel-list commands need a comma before the list:** `OUTP OFF,(@3)`.
The space form `OUTP OFF (@3)` is rejected with `-103,"Invalid separator"` and
does **nothing at all** — it does not even error out to the caller. A power cycle
written that way silently runs to completion while the rail stays up. Always read
`OUTP? (@ch)` back after a state change.

## Channel map

| ch | setpoint | output | load | notes |
|---|---|---|---|---|
| 1 | 12 V / 2 A | **off** | — | spare |
| 2 | 12 V / 2 A | **off** | — | spare |
| 3 | 5 V / 2 A | **on** | **Zynq** (AC7Z020 SoM, 5 V input per §5 of the design doc) | ~2.13 W |
| 4 | 12 V / 3.06 A | **on** | **K7 / A7** board | ~22.0 W |

## Baseline (2026-10-29, 5 s @ 2 Hz, `baseline_5s.csv`)

| ch | V | I | P | I range |
|---|---|---|---|---|
| 3 | 5.0033 V | 0.4251 A | 2.127 W | ±0.0001 A — flat |
| 4 | 12.0056 V | 1.8289 A | 21.96 W | 1.8152–1.8375 A — switching load |

CH3 sits at 21 % of its current limit, CH4 at 59 %; neither is in CC, so both
measurements are trustworthy.

## Two things to watch

1. **CH4's 22 W is the K7/A7 board, not the JSM module.** Do not use it as a
   data point against the §7 budget (12 V / 0.14–0.42 A); the JSM prototype will
   be a different load and needs its own rail.
2. **CH4 has only 1.2 A of headroom and OCP is disabled** (`CURR:PROT:STAT?` → 0).
   An FPGA reconfiguration inrush on a K7 board can approach that. If CH4 starts
   to collapse during programming, that is inrush hitting the 3.06 A limit, not a
   board fault — raise the limit before suspecting the hardware.

## Power-cycle CH3 (Zynq), 2026-10-29 20:33 — `cycle_ch3.csv`

Sequence: 2.0 s off → on, sampled at 18.2 Hz (V+I every sample).

| moment | value |
|---|---|
| before cycle | 0.2781 A @ 5.0034 V — **abnormal**, see below |
| while off (verified) | 0.0000 A, **+1.396 V present on the rail** |
| 90 % of settle | t+3.84 s |
| peak | 0.5444 A at t+6.61 s (boot transient) |
| after | 0.4233 A @ 2.118 W ≈ the 16:19 baseline (0.4251 A) |

Per-second current: 0.33 → 0.37 → 0.37 → 0.39 → 0.46 → 0.44 → 0.46 (peak) → 0.45.
Shape matches a PetaLinux boot: DDR + A9 coming up, a bump as the GbE PHY links,
then steady state.

### ⚠ Back-drive on CH3 when the rail is off

With the 5 V output off, the channel reads a **flat 1.396 V** and sinks −0.23 mA
for the whole 2 s. That is not capacitor decay — it is a steady source energizing
the Zynq board while its own supply is dead. This is exactly the failure mode
§4 of the design doc calls out for the JSM's 3.3 V output.

Most likely path: a lower rail (~1.8 V) is being held up from outside — the K7/A7
board's I/O across the inter-board link, or the USB-UART's VBUS — and it feeds
back through the 5 V→1.8 V converter's body diode (1.8 − ~0.4 = 1.4 V).

Confirm by repeating the off-state measurement with the inter-board cable pulled;
if 1.4 V disappears, the K7 board is the source and the Zynq is sitting in a
half-powered state every time CH3 is cycled. Worth fixing in the JSM (ideal-diode
OR / reverse-blocking load switch on the target-facing 3.3 V) before it burns a
TAP.

### State note

Before the cycle CH3 sat at 0.278 A for at least several minutes, and CH4 dropped
from 1.83 A to 1.36 A across the same 4 h gap. After the cycle CH3 came back to
0.423 A (= the earlier healthy baseline). So the Zynq had drifted into a
lower-current state on its own — hung PS or unconfigured PL — and the power cycle
cleared it. Not a supply problem.

## Power-cycle CH4 (K7/A7), 2026-10-29 21:27 — `cycle_ch4.csv`

2.0 s off → on, 29.1 Hz. Limit 3.06 A, OCP still disabled.

| moment | value |
|---|---|
| before cycle | 1.3779 A @ 12.0058 V |
| while off (verified) | 0.0000 A, **0.106 V** residual |
| 90 % of first plateau | t+0.53 s |
| plateau 1 s → 8 s | ~1.38 A |
| **step at t+8 s** | +0.45 A (≈5.4 W) in <1 s → 1.83 A |
| min V during ON | 12.0066 V (**no sag**) |
| after | 1.8314 A @ 12.0058 V = **21.99 W** |

No inrush overshoot worth the name: the first sample after ON is already 1.26 A and
the peak of 1.83 A is the steady state, not a transient. Headroom at peak +1.23 A,
so the 3.06 A limit never came close — the inrush worry was unfounded on this load.

The t+8 s step is the board's own power sequencing (a delayed rail/load switch or
DDR calibration), not the supply.

### Contrast: back-drive is a Zynq-side problem, not the K7

CH4 off → **0.106 V**. CH3 off → **1.396 V**. The K7 board does not hold up its own
12 V input, so the K7's I/O across the inter-board link is *not* what is energizing
the Zynq. The 1.4 V source is on the Zynq side — a lower rail of that board being
fed from outside (USB-UART VBUS is the remaining candidate) or simply its own
capacitance held by a 1.8 V regulator body diode. Narrow it down by unplugging the
Zynq's USB-UART and repeating the CH3-off read.

### Both boards had drifted, cycles restored them

| rail | 16:19 baseline | 20:29 (before any cycle) | after cycle |
|---|---|---|---|
| CH3 Zynq | 0.4251 A | 0.2781 A | 0.4243 A |
| CH4 K7/A7 | 1.8338 A | 1.3779 A | 1.8314 A |

The instrument's own readings never shifted (CH1/CH2 still read ~1 mV), so this was
the boards, not the meter: both had fallen into a lower-power state over the 4 h gap
and a power cycle brought both back to exactly their baseline. Something on the host
side stopped driving them (Vivado/hw_server was not running) or both boards wedged.

## CH3 left OFF, 2026-10-30 10:51

`OUTP OFF,(@3)` → verified `OUTP?` = 0. CH4 untouched and still on.

Off-state rail held **1.399 V for 10 s, flat to ±1 mV**, sinking 0.22 mA the whole
time. Not capacitance: a 10 s hold at constant voltage with steady current is a live
source behind a high-ish impedance. This is now a standing test point — with CH3 off
and the board parked, pulling the USB-UART (or the inter-board link) and re-reading
CH3 identifies the source in one move.

Note the drift repeated after the 13 h gap: CH3 0.275 A and CH4 1.351 A before the
cycle, i.e. both boards back in the low-current state. Two for two, so it is
reproducible behaviour of the bench, not a one-off.

## ⚠ CH4 went off on its own, 2026-10-30 10:51

Sequence, all within ~60 s:

1. 10:50:33 — status: CH3 ON 0.2753 A, CH4 ON 1.3514 A.
2. 10:50:5x — `OUTP OFF,(@3)`; verified `OUTP? (@3)` = 0. CH3 then held its usual
   1.399 V back-drive flat for 10 s at −0.22 mA.
3. 10:51:1x — status: **CH4 now also off** (0.0739 V), and CH3's back-drive had
   collapsed to 0.006 V. No errors in the queue.

Not caused by my command: only channel 3 was addressed, and the instrument reports
`+0,"No error"`. `OUTP:PROT:TRIP?` and `MEAS:TEMP?` are unsupported on this firmware,
so a protection trip cannot be ruled out by query — but a 22 W load on a 300 W channel
is nowhere near a thermal limit.

The useful clue is the *back-drive collapsing at the same moment*. Whatever was
holding the Zynq's 5 V input at 1.4 V also lost power at that instant, which points
at something bench-side (a power strip, the USB-UART's host port, the inter-board
link) rather than at the N6705C's output switch.

`OUTP:PON:STAT?` = `RCL0` — on power-up the instrument recalls state 0, which could
restore outputs on its own. Check state 0 before trusting that.

## All channels OFF, 2026-10-30 16:14

`OUTP OFF,(@1,2,3,4)` → all four verified `OUTP?` = 0, `+0,"No error"`.

| ch | before | after (2 s) |
|---|---|---|
| 1 | off | 1.2 mV |
| 2 | off | 1.0 mV |
| 3 | ON 5.0034 V 0.4613 A 2.31 W | 15.6 mV |
| 4 | ON 12.0056 V 1.4281 A 17.15 W | 64 mV |

### Correction: the Zynq back-drive DOES come from the K7 side

Earlier note (10:51) said the K7's I/O was "not the source" because CH4-off read only
0.106 V. That reasoning was wrong — it answered a different question (does the K7 hold
up its own 12 V input). The decisive evidence was already in hand: when CH4 went off at
10:51, CH3's 1.399 V collapsed to 0.006 V **at the same instant**, and now with all four
channels off CH3 sits at 11-16 mV.

So the chain is: K7/A7 (CH4) → inter-board I/O holds the Zynq's lower rail up →
5 V→1.8 V converter body diode → 1.4 V on the Zynq's 5 V input while CH3 is off. The
Zynq is half-powered every time CH3 is cycled with CH4 live. Exactly the §4 back-drive
hazard, and it is a real one on this bench, not a theory.

Confirm by powering CH4 alone with CH3 off and watching CH3's measured voltage climb to
~1.4 V. That is a 30 s test and it nails the source.

## CH3 + CH4 back ON, 2026-10-30 16:20

Enabled CH3 first, CH4 250 ms later (avoids a back-drive window on the Zynq before its
own rail is up). Both verified `OUTP?` = 1, `+0,"No error"`. 20 s @ ~2 Hz:

| rail | settle | note |
|---|---|---|
| CH3 | 0.4582 A @ 5.0032 V = **2.293 W** | plateaus by t+2 s, then flat |
| CH4 | 1.4281 A @ 12.0053 V = **17.12 W** | ~1.41–1.43 A throughout |

CH3 sits ~8 % above its 0.4251 A baseline; CH4 sits in the lower of its two states.

### The CH4 "t+8 s step" did not happen this time

Earlier (21:27 cycle) CH4 held 1.38 A for 8 s then stepped to 1.83 A. This run it stayed
at 1.41–1.43 A for the full 20 s. So that step is **not** a fixed board power-sequencing
stage as recorded earlier — it is conditional on something else (a bitstream being loaded,
a link coming up, or an external agent). CH4 has at least two stable states, ~1.43 A and
~1.83 A, and they are not distinguished by anything the supply can see. Correct the
earlier note accordingly when judging "is the K7 up".

## Back-drive source CONFIRMED — CH3 cycled with CH4 down, 2026-10-30 18:23

`cycle_ch3b.csv`. Same 2 s cycle as before, only difference: **CH4 was off.**

| | CH4 live (20:33 / 10:51) | CH4 down (18:23) |
|---|---|---|
| CH3 off-state V | **1.396–1.399 V** | **0.0427 V** |
| CH3 off-state I | −0.22 mA | +0.02 mA |

Nothing else changed. That is the controlled A/B: the 1.4 V on the Zynq's 5 V input is
supplied through the K7/A7 board. Case closed — the JSM needs reverse blocking on the
target-facing rail, and until then CH3 must never be cycled with CH4 live if a clean
TAP state matters.

Boot curve this time (CH4 down, SD card re-seated):

    0.327 → 0.371 → 0.369 → 0.425 → 0.460 → 0.445 → 0.457 → 0.461 → 0.432 → 0.460 → 0.442 → 0.458 A

with narrow 0.516 A spikes at t+6–7 s (Ethernet link / PHY), then decaying to a steady
**0.4188 A = 2.095 W**. Peak 1.13x steady, min V 5.0039 V — no sag, 1.48 A of headroom.
The 0.45 A "settled" figure in the script is the median of a window that still contains
the link-up bump; the true post-boot steady state is 0.419 A.

## Back-drive proven with one variable, 2026-10-31 11:50

CH3 output OFF, CH3 sat at 9.9 mV. Powered **CH4 only** (CH3 never commanded, never touched):

| t | CH3 dead rail | CH4 I |
|---|---|---|
| 0.1 s | 0.119 V | 1.102 A |
| 0.7 s | 0.308 V | 1.324 A |
| 1.4 s | **1.440 V** | 1.319 A |
| 1.4–10 s | 1.4386 V (flat, ±1 mV) | ~1.30 A |

The Zynq's 5 V input climbs to 1.44 V inside the K7's own ramp and stays there. No other
variable changed. This is not inference any more — energising the K7 back-powers the dead
Zynq.

**Consequence:** while CH3 is off and CH4 is on, the Zynq is half-powered — 5 V input at
1.44 V, lower rails presumably up. The TAP state is indeterminate in that condition, and
the FPGA's I/O are being driven by a live K7 through their clamp diodes. Never run JTAG
against the Zynq in this state, and never leave the bench this way.

## Dual cycle again, 2026-10-31 17:44 — `cycle_both2.csv`

Both rails up, CH3 already drifted to 0.2775 A (the low state) after 4.6 h idle.

| phase | CH3 | CH4 |
|---|---|---|
| pre | 5.0035 V / 0.2775 A | 12.0058 V / 1.2834 A |
| K7 off | 0.2752 A | 0.108 V / 0 |
| Zynq off | **0.0450 V** / 0 | 0.0455 V / 0 |
| Zynq boot | 0.3778 A | 0.030 V |
| K7 on | 0.4463 A | 1.3805 A |
| settled (+20 s) | **0.4188 A = 2.095 W** | **1.4081 A = 16.91 W** |

### The 0.275 A low state: 3 for 3

CH3 drops from ~0.42 A to ~0.275 A after a few idle hours, every time, and a power
cycle brings it straight back to 0.4188 A:

| before cycle | after cycle |
|---|---|
| 0.2781 A (30 Oct 20:29) | 0.4243 A |
| 0.2753 A (30 Oct 10:50) | 0.4613 A |
| 0.2775 A (31 Oct 17:43) | 0.4188 A |

Either the Zynq hangs (Linux wedged, PL unconfigured) or it parks itself in a low-power
mode when nothing drives it. The supply cannot tell which. For a 24/7 module this matters:
whatever the JSM's own firmware does, it must not silently lose 35 % of its current draw
and become unreachable. Check the serial console after an idle period to see whether the
kernel is alive.

## Dual cycle #2, 2026-10-31 17:59 — `cycle_both3.csv`

15 min after the previous cycle, both rails up (CH3 0.4378 A, CH4 1.4089 A — no drift
yet this soon after a cycle).

| phase | CH3 | CH4 |
|---|---|---|
| off3 | 0.0448 V / 0 | 0.0442 V / 0 |
| boot | 0.3803 A | — |
| settled (+15 s) | **0.4198 A = 2.100 W** | **1.3934 A = 16.73 W** |

Identical to the 17:44 cycle to within 1 % (0.4188 vs 0.4198 A; 1.4081 vs 1.3934 A),
with the same 45 mV off-state and 0.38 A boot plateau. The cycle is repeatable, and
0.419-0.420 A is the reliable post-boot Zynq figure — the 0.44-0.47 A readings are always
boot tail.
