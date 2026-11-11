# jsmdisp — SSD1315 OLED IP display

Front-panel status display for XJSM-P12-Z7000. It renders the top line of the
layout in [`XJSM-P12-Z7000-Design-Proposal.md`](../../XJSM-P12-Z7000-Design-Proposal.md) §4.4.4:

```
┌────────────────────────────────┐
│ 192.168.001.100            ●   │   ← 8×16 font, fixed-width 3-digit octets,
├────────────────────────────────┤      1 Hz heartbeat dot
│            (channel grid, not yet implemented)          │
├────────────────────────────────┤
│ XJSM-P12-Z7000                 │
└────────────────────────────────┘
```

The panel is driven straight through `i2c-dev` (`/dev/i2c-N`, address `0x3C`),
no DRM/fbtft and no kernel driver — exactly the strategy in §4.4.5.

## Files

| File | Purpose |
|---|---|
| `jsmdisp.c` | the program (framebuffer, 8×16 font, IP discovery, heartbeat) |
| `font8x16.h` | generated 8×16 ASCII font (public-domain VGA console font) |
| `Makefile` | native or cross build |

## Build

On the target:

```sh
make
```

Cross build with the PetaLinux SDK (adjust the tuple to your toolchain):

```sh
make CC=aarch64-linux-gnu-gcc
```

## Run

```sh
./jsmdisp                 # autodetect the bus, show the IP, blink forever
./jsmdisp -b /dev/i2c-1   # force a bus
./jsmdisp -i 10.0.0.42    # force the displayed string
./jsmdisp -t              # test pattern, then exit
./jsmdisp -n -i 1.2.3.4 -x frame.pbm -o   # render offline, no hardware
```

`SIGINT`/`SIGTERM` exit cleanly and leave the last frame on the panel.

## Wiring (AX7Z020B dev board, J20 header)

| OLED | J20 pin | Zynq ball | Note |
|---|---|---|---|
| SCL | **35** | `V15` (IO34_L10P) | 4.7 kΩ to 3.3 V (internal `PULLUP` is enabled but weak) |
| SDA | **33** | `U20` (IO34_L15N) | 4.7 kΩ to 3.3 V (internal `PULLUP` is enabled but weak) |
| VDD | 39 or 40 | — | 3.3 V |
| VBAT | 39 or 40 | — | 3.3 V (charge-pump input, ≥ VDD) |
| GND | 1, 37, 38 | — | connect first |

Do **not** use J20 pin 2 (+5 V). J21 is also 3.3 V by default but its bank can be
jumpered to 1.8/2.5 V (J28/J29), which would conflict with 3.3 V pull-ups — stay
on J20.

**Internal pull-ups:** `constraints/oled_i2c.xdc` sets `PULLTYPE PULLUP`, which
uses the 7-series IOB weak pull-up (~10–50 kΩ). It is enough to bring a short
bench hookup up at **100 kHz**, but it is not I²C-compliant: with 30 pF and 50 kΩ
the rise time is already ~1.3 µs (the 100 kHz limit is 1 µs, 400 kHz is 300 ns).
Keep the DT at `clock-frequency = <100000>` while relying on it, and fit real
4.7 kΩ resistors (2.2 kΩ for 400 kHz) for anything permanent.

Check the module you have: 4-pin I²C modules usually carry their own 4.7 kΩ
pull-ups. If they go to **3.3 V**, do not add a second pair in parallel (2.35 kΩ
is still usable but needlessly strong); if they go to 5 V, cut/remove them —
5 V on a 3.3 V PL pin is out of spec.

If you use the bare 30-pin panel instead of a 4-pin module, the adapter must
also carry the charge-pump caps (C1/C2 = 1 µF), VCC = 4.7 µF, VCOMH = 2.2 µF,
IREF resistor, and the I²C straps: `BS0=0`, `BS1=1`, `CS#=0`, `D/C#=0`.

## FPGA side

`J20-35/33` are plain PL pins, so something has to be an I²C master there.
`xvc/vivado/build_g1_oled.tcl` adds **PS7 I2C1 → EMIO → IOBUFs → V15/U20**
(keeping I2C0 on MIO50/51, the on-board EEPROM/RTC bus, untouched):

```sh
cd xvc/vivado
vivado -mode batch -source build_g1_oled.tcl
```

It produces `out_g1_oled/system_wrapper.bit` and `out_g1_oled/system.xsa`.
Rebuild the PetaLinux image from the new XSA so the `i2c1` node appears:

```sh
petalinux-config --get-hw-description=<path>/out_g1_oled
petalinux-build
```

The PetaLinux project already pins this bus to 100 kHz in
`xvc/petalinux/xvc/project-spec/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`:

```dts
&i2c1 {
    status = "okay";
    clock-frequency = <100000>;
};
```

100 kHz is deliberate while the FPGA's weak IOB pull-up is the only pull-up.
Raise it to 400 kHz only after fitting 2.2 kΩ external resistors to 3.3 V.

Then the panel is `/dev/i2c-1`:

```sh
i2cdetect -y 1        # 0x3C must answer
./jsmdisp -b /dev/i2c-1
```

Notes:

* The PS7 EMIO I2C needs all three config properties
  (`PCW_EN_I2C1`, `PCW_EN_EMIO_I2C1`, `PCW_I2C1_I2C1_IO=EMIO`); setting only
  `EN_EMIO_I2C1` leaves the controller unmapped and no `I2C1_*` pins appear.
* `rtl/i2c_emio.v` : `*_i` ports are **outputs** (buffer → PS7), `*_o`/`*_t`
  are inputs. Getting this backwards produces "net already has a source".

### Fast path without touching the FPGA

If you just want to see the panel light up today: the dev board's PS **I2C0**
is already enabled on **MIO50/51** and already level-shifted to 3.3 V (the
EEPROM 24LC04 / RTC DS1338 bus, `I2C_SCL`/`I2C_SDA` nets after the TXS0102).
Tap SCL/SDA/GND/3.3 V there and run `./jsmdisp -b /dev/i2c-0`. The OLED answers
at 0x3C and does not collide with 0x50/0x68.

## Register map recap (SSD1315, I²C)

* Address `0x3C` (7-bit) with `D/C#` = GND; `0x3D` if `D/C#` = VDD.
* Control byte `0x00` = command stream, `0x40` = GDDRAM data stream.
* Init: `AE D5 80 A8 3F D3 00 40 8D 14 20 00 A1 C8 DA 12 81 CF D9 F1 DB 40 A4 A6 2E AF`.
* Window: `21 00 7F` (columns), `22 00 07` (pages), then 1024 data bytes.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `i2cdetect` shows nothing | PL bitstream not loaded, wrong pins/pull-ups, panel unpowered |
| `no ACK from 0x3C` | no 4.7 kΩ pull-ups, SCL/SDA swapped, VBAT not connected |
| Panel dark but ACKs | charge pump caps missing (bare panel), VCC shorted to 3.3 V |
| Everything inverted / mirrored | flip `0xA1/0xA0` and `0xC8/0xC0` in `panel_init()` |
| Display wedges (SDA stuck low) | power-cycle; on the carrier add a load switch or a RES# GPIO |

## Autostart

`/etc/systemd/system/jsmdisp.service`:

```ini
[Unit]
Description=OLED IP display
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/jsmdisp -b /dev/i2c-1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```
