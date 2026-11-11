# oled_i2c.xdc - SSD1315 front-panel OLED, I2C mode
#
# AX7Z020B J20 header (BANK34, fixed 3.3 V):
#   J20 pin 35 = V15 = IO34_L10P -> SCL
#   J20 pin 33 = U20 = IO34_L15N -> SDA
#   J20 pin 39/40 = +3.3 V, pin 1/37/38 = GND
#
# Typical panel: VDD = VBAT = 3.3 V, address 0x3C (D/C# = GND).
# These pins drive through IOBUFs from PS7 EMIO I2C1 (see rtl/i2c_emio.v).
#
# PULL-UPS
#   PULLTYPE PULLUP enables the 7-series IOB weak pull-up (~10k..50k, process
#   dependent).  It is a bring-up convenience only, NOT an I2C-compliant
#   termination:
#     tr ~= 0.847 * Rp * Cbus
#     50k with 30 pF  -> ~1.3 us  (100 kHz limit is 1.0 us, 400 kHz is 300 ns)
#   So: use it with 100 kHz and short wires.  For anything beyond a bench test
#   fit 4.7k (or 2.2k for 400 kHz) from SCL and SDA to 3.3 V externally; the
#   internal pull-up then just sits in parallel and does no harm.

set_property PACKAGE_PIN V15 [get_ports i2c_scl]
set_property PACKAGE_PIN U20 [get_ports i2c_sda]

set_property IOSTANDARD LVCMOS33 [get_ports {i2c_scl i2c_sda}]
set_property PULLTYPE PULLUP    [get_ports {i2c_scl i2c_sda}]
set_property DRIVE   8          [get_ports {i2c_scl i2c_sda}]
set_property SLEW    SLOW       [get_ports {i2c_scl i2c_sda}]
