# XJSM-P12-Z7000 Design Proposal

> Platform: AX7Z020B (XC7Z020-2CLG400) + external AMD Xilinx FPGA chain
> Goal: Ethernet remote debug + front-panel OLED status display
> Date: 2026-10-30

---

## 1. Overall Architecture

```
              ┌──────────────────────────── PC / Vivado ───────────────────────────┐
              │  hw_server  ── XVC over TCP ──►  192.168.1.113:2543                 │
              └───────────────────────────────────┬─────────────────────────────────┘
                                                  │
                    ┌─────────────────────────────▼──────────────────────────────┐
                    │                    Zynq PS (Linux)                         │
                    │  xvcserver: /dev/mem access to 0x43C00000                   │
                    │  oled_ip : /dev/i2c-1 -> SSD1315 OLED                       │
                    └───────┬───────────────────────────────────┬────────────────┘
                            │ AXI4-Lite (GP0)                   │ PS I2C1 / EMIO
                    ┌───────▼────────┐                  ┌───────▼────────┐
                    │ PL: jtag_ctrl  │                  │ PL: i2c_emio   │
                    │  32-bit shifter│                  │  (IOBUF open-drain) │
                    └───────┬────────┘                  └───────┬────────┘
                            │ TCK/TMS/TDI/TDO                   │ SCL/SDA
                    ┌───────▼────────┐                  ┌───────▼────────┐
                    │ J20 pin3-6     │                  │ J20 pin35/33   │
                    │ K7 + A7 chain  │                  │ SSD1315 OLED   │
                    └────────────────┘                  └────────────────┘
```

## 2. Hardware Interfaces

### 2.1 JTAG (G1)

| Signal | J20 pin | Device pin |
|---|---|---|
| TCK | pin 3 | R14 |
| TMS | pin 4 | P14 |
| TDI | pin 5 | U12 |
| TDO | pin 6 | T12 |

### 2.2 OLED (SSD1315, I2C)

| Signal | J20 pin | Device pin | Notes |
|---|---|---|---|
| IIC_SCL | **pin 35** | **V15** (IO34_L10P) | PS I2C1 via EMIO |
| IIC_SDA | **pin 33** | **U20** (IO34_L15N) | PS I2C1 via EMIO |
| VCC | pin 39/40 | — | +3.3 V |
| GND | pin 1/37/38 | — | GND |

- Panel address **0x3C** (D/C# tied to GND), 128×64, I2C mode
- 7-series IOB weak pull-ups (PULLTYPE PULLUP) are adequate for bench debugging only:
  roughly 10k–50k, usable at 100 kHz with short wires; for production add external
  **4.7k** pull-ups to 3.3 V

## 3. PL Design

### 3.1 jtag_ctrl (AXI4-Lite slave, base 0x43C00000)

| Offset | Name | Description |
|---|---|---|
| 0x00 | LENGTH | Bits to shift this transaction (≤32) |
| 0x04 | TMS | TMS bit vector |
| 0x08 | TDI | TDI bit vector |
| 0x0C | TDO | TDO read-back |
| 0x10 | CTRL | bit0 start (self-clearing), bit1 busy |
| 0x14 | DIV | TCK half period = DIV clocks (100 MHz / 2DIV) |
| 0x18 | STATUS | Busy flag (high byte is a version tag) |

- Shift engine: single phase counter, exactly one TCK rising edge per bit
- TDO is sampled at the midpoint of the high phase

### 3.2 i2c_emio (EMIO tri-state bridge)

PS7 I2C1's `SCL_I/O/T`, `SDA_I/O/T` connect through IOBUFs to V15/U20:

```
PS7 EMIO            IOBUF            board
I2C1_SCL_O  ──►  I  ──►  i2c_scl  (open-drain, external pull-up)
I2C1_SCL_I  ◄──  O  ◄──
I2C1_SCL_T  ──►  T (1 = high-Z)
```

## 4. Software Design

### 4.1 xvcserver (port 2543)

| Item | Description |
|---|---|
| Protocol | XVC 1.0: `getinfo:` / `settck:<ns>` / `shift:<bits><tms><tdi>` |
| Max shift | 4,194,304 bit (4 Mbit) — Vivado actually requests 523,511 bit |
| TCK | 10 MHz by default (`-d 5`); `settck` can slow it down |
| Concurrency | fork-per-client + `flock` to serialize the bus |
| Robustness | `read_full` / `write_full` (short reads/writes), 1 MB socket buffer |
| Statistics | prints `STAT bits=… elapsed=… rate=…` when a connection ends |

### 4.2 oled_ip (OLED IP display)

```
main()
 ├─ open /dev/i2c-1, I2C_SLAVE=0x3C
 ├─ oled_init()      SSD1315 init (charge pump, multiplex ratio, COM scan dir…)
 ├─ get_ip("eth0")   ioctl(SIOCGIFADDR)
 ├─ render()         5×7 font rendered into a 128×64 framebuffer
 │     "IP ADDR"       2× scale
 │     "192.168.1.113" 2× if ≤10 chars, else 1×
 │     "eth0 :2543"     1×
 └─ oled_flush()     page-wise write of 8×(1+128) bytes
```

- Polls the IP every 5 seconds and redraws on change
- Startup script `/etc/init.d/oled_ip`, `rc5.d/S98oled_ip`

## 5. Build Flow

```bash
# 1. PL (two variants)
vivado -mode batch -source xvc/vivado/build_g1.tcl        # XVC high-speed variant (18 s program)
vivado -mode batch -source xvc/vivado/build_g1_oled.tcl   # OLED variant (GPIO JTAG + I2C)

# 2. PetaLinux
petalinux-config --get-hw-description=<out_dir> --silentconfig
petalinux-build
petalinux-package --boot --fsbl zynq_fsbl.elf --fpga system.bit --u-boot u-boot.elf

# 3. Deploy (always verify md5 first)
xvc/tools/flash_board.sh   # download to /tmp → verify md5 → write to SD
```

> **Note**: `petalinux-build` regenerates `images/linux/system.bit` from the XSA in
> the project, so the correct order is **build first → copy the bitstream → package last**.

## 6. Verified Metrics

| Item | Result |
|---|---|
| XVC remote programming | **18.0–18.5 s**, 10 consecutive runs, 100% success |
| USB JTAG cable baseline | 9.56 s |
| Chain identification | A7 `0x0362C093` / K7 `0x43651093` |
| BYPASS data integrity | 60,000 bit, 0 errors |
| Network integrity | 32 MB MD5 match (59 MB/s) |
| PL resources | LUT 3.9% / FF 2.7% / BRAM 1.8% |

## 7. Key Problems and Root Causes (lessons learned)

| # | Symptom | Root cause | Fix |
|---|---|---|---|
| 1 | Chain scan OK, programming drops immediately | `getinfo` advertised 65536 bit, Vivado requested 523,511 | Raise the limit to 4 Mbit |
| 2 | RTL changed but behaviour unchanged | `petalinux-build` overwrites `system.bit` | Reorder the build steps |
| 3 | Programming only 5 Mbit/s | DIV written to read-only 0x18 (the real one is 0x14) | Fix the address |
| 4 | Image flashing "succeeded" but had no effect | SD card full → 0-byte file moved by `mv` | Download to /tmp + verify md5 |
| 5 | `open_hw_target` intermittently fails | hw_server disconnects proactively (data is correct) | Retry 8 times |

## 7.1 OLED Implementation Progress (2026-10-30)

| Stage | Result |
|---|---|
| PS EMIO I2C approach (`build_g1_oled.tcl`) | ✅ Synthesizes, but the FSBL built from that XSA does not boot |
| Merged approach (`build_g1_oled2.tcl`) | ✅ Synthesizes, FSBL also does not boot |
| **PL bit-bang I2C approach (`build_g1_oled3.tcl`)** | ✅ Builds, AXI address `0x43C10000` verified readable/writable |
| Linux app `oled_ip` (C, `-m` uses /dev/mem) | ✅ Source complete, cross-compiles into the image |
| Pure-shell test script `oled_shell.sh` | ✅ Generated (precomputed framebuffer + devmem bit-bang) |
| **Bring-up on hardware** | ⏳ Pending verification (see `docs/OLED_TEST_STEPS.md`) |

**Why the PL approach was chosen**: the PS EMIO approach requires modifying the FSBL,
and after rebuilding the FSBL in this project the board would not boot. The PL
approach only needs a bitstream load (18 s), does not affect boot at all, and if
something goes wrong the old bitstream can be restored immediately.

## 8. Current Status and Next Steps

| Item | Status |
|---|---|
| XVC high-speed variant (jtag_ctrl) | ✅ Stable, 18 s |
| OLED PL + `oled_ip` application | ✅ Implemented and built |
| OLED image bring-up on hardware | ⚠️ Image fails to boot (FSBL anomaly after rebuild); pending recovery |
| FIFO streaming acceleration | ⏸ Underflow bug fixed, a second hang remains |
| Flash (S25FL256Sxxxxxx1) programming | ⏸ Part confirmed, speed unacceptable |

**Recommendations**
1. Restore the SD card to a stable image, then verify the OLED separately (or use a
   merged `jtag_ctrl + i2c_emio` design to avoid two PL variants);
2. Merged design: add `i2c_emio` + PS I2C1 EMIO to `build_g1.tcl` to get a single
   "high-speed XVC + OLED" image;
3. FIFO streaming: use an ILA to capture `stream_chunk / tx_empty / running / rx_full`
   and locate the second hang.
