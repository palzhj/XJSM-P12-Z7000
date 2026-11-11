# OLED (SSD1315) Verification Steps — Checklist for Back in the Lab

> ⚠️ **Historical document** (bit-flip experiment phase, 2026-10-30)
> See [`STATUS.md`](STATUS.md) and `oled_current.png` for the final version
> `oled_ip` is now baked into the current image; this method is no longer needed


> Goal: display the local IP on the 0.96" OLED attached to the J20 expansion header
> Hardware: SCL = J20 pin35 (V15), SDA = J20 pin33 (U20), 3.3 V, address 0x3C

---

## 0. Current state (when leaving the lab)

| Item | State |
|---|---|
| Board | ❌ Does not boot (`image.ub` on the card = `e2b80437`, incompatible with U-Boot) |
| SD card | Inside the board |
| Card backup | ✅ `BOOT.BIN.ok` (`b6ae0dfc`), `image.ub.ok` (`f14145e0`) |
| PL-side I2C master | ✅ Implemented and built (`out_g1_oled3`, AXI `0x43C10000`) |

## 1. Restore boot (mandatory first step)

1. Power off, remove the SD card, plug it into a PC;
2. On the card's FAT partition:
   ```
   delete image.ub
   rename image.ub.ok   to image.ub
   confirm BOOT.BIN is b6ae0dfc (if not, rename BOOT.BIN.ok to BOOT.BIN)
   ```
3. Reinsert the card into the board and power on;
4. Confirm `ping 192.168.1.113` succeeds.

## 2. Program the PL with the I2C master

```bash
./xvc/tools/program_and_log.sh xvc/vivado/out_g1_oled3/system_wrapper.bit 10 "OLED test"
```

About 18 s. After programming, verify the registers:

```bash
# board serial console
devmem 0x43C10000 32        # write 3, should read back 3
devmem 0x43C10004 32        # bit0=SDA, bit1=SCL
```

## 3. Run the OLED test (pure shell, no extra software)

Start an HTTP server on the host:

```bash
cd xvc/out/oled_py && python3 -m http.server 8013
```

Run on the board's serial console:

```bash
wget -q http://192.168.1.50:8013/oled_shell.sh -O /tmp/o.sh
sh /tmp/o.sh
```

- The script uses `devmem` to toggle the SCL/SDA bits at `0x43C10000`, emulating I2C timing;
- Expect **3-5 minutes** (about 3 devmem accesses per bit, roughly 30,000 in total);
- The screen should show:

```
▢ ▢ ▢ ▣ ▢ ▢ ▣ ▢ ▢ ▢ ▢ ▢      ← status boxes (top-aligned)
12 11 10 9 8 7 6 5 4 3 2 1     ← port numbers
Broadcast ⊡      10.0MHz
192.168.1.113                   ← IP (bottom-aligned)
```

## 4. Interpretation

| Symptom | Meaning | Next step |
|---|---|---|
| Displays correctly | ✅ Hardware and I2C timing are both right | Bake `oled_ip` into the image (optional) |
| Garbled/partial display | Timing too fast or pull-up insufficient | Add external 4.7k pull-ups; or lower the refresh rate |
| All black but no NACK | Address or init sequence differs | Try address 0x3D; confirm D/C# is grounded |
| `NACK on ...` printed | Slave not responding | Check whether SCL/SDA are swapped, verify 3.3 V supply |

## 4.1 Pin alternatives (important)

Per **Table 2.17.1** of the *AX7Z020B User Manual* (J20 expansion header ZYNQ pin assignment), verbatim:

```
  33               U20                 34          T20
  35               V15                 36          W15
```

And the IO name mapping from the same manual:

```
  IO34_L10P    V15     IO34_L10N    W15
  IO34_L15N    U20     IO34_L15P    T20
```

Mapping in this project (**matches the manual, confirmed**):

| J20 pin | FPGA ball | IO name | Use |
|---|---|---|---|
| 33 | **U20** | IO34_L15N | SDA |
| 35 | **V15** | IO34_L10P | SCL |
| 36 | W15 | IO34_L10N | (unused in this project) |

Online examples often list SDA as **W15**, but that is pin 36 (IO34_L10N), not pin 33. If your board actually has W15,
change `U20` to `W15` in `constraints/oled_pl_i2c.xdc` and rebuild:

```tcl
set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports i2c_sda]
```

How to decide: if the OLED does not respond (the script prints `NACK`), first use a multimeter to determine which of pin33/pin36 is SDA,
then change the constraint and reprogram (18 s).

## 4.2 Measured results (2026-10-30 evening)

| Item | Result |
|---|---|
| PL I2C master registers | ✅ `0x43C10000` is readable/writable, `STATUS=3` when `CTRL=3` (both lines idle high) |
| Open-drain polarity bug | ✅ Fixed (previously `ctrl=1` pulled the line low; now `ctrl=1` = release) |
| OLED response | ❌ **NACK** (addresses 0x3C / 0x78, NACK both before and after the fix) |
| Probe script | ⚠️ Hangs the console (Ctrl+C required); root cause not determined |

**Conclusion**: The software timing and the PL path are verified working (the bus can pull high/low correctly), but the OLED does not respond.
Most likely causes (in order of likelihood):

1. **SCL/SDA swapped** (module pins 3=SCL, 4=SDA; the actual wiring order may be reversed);
2. **Pin mapping**: the manual says pin33=U20, but the module may be connected to W15 (pin36);
3. **Insufficient pull-up**: if the module lacks built-in 4.7k, weak pull-ups still work at 5 µs timing, but wire length/interference can break them;
4. Module power (VCC/GND) or D/C# grounding issue.

**Next steps (require lab access)**:
1. Use an oscilloscope/logic analyzer to check for waveforms on V15/U20 (quick way to verify wiring);
2. **Swap** the two SCL/SDA wires and retry;
3. Rebuild with the W15 pin and reprogram (constraint change, 18 s);
4. Use a multimeter to measure the resistance from SDA/SCL to 3.3V (there should be a pull-up).

## 5. Known limitations

- The board has no python3 and no `i2c-tools`, so only `devmem` is available;
- The PL-side I2C is "software bit-banging" at about 10 kHz, so full-screen refresh is slow;
- To show the IP automatically at boot, `oled_ip` (C version, `-m 0x43C10000`) must be built into `image.ub`,
  and the new `image.ub` is incompatible with the current U-Boot — image compatibility must be resolved first.
