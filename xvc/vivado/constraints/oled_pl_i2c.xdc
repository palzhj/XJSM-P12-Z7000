# oled_pl_i2c.xdc - PL-side I2C master pins (J20)
#   J20 pin 35 = V15 = SCL
#   J20 pin 33 = U20 = SDA
# Open-drain output is implemented with IOBUF; the internal weak pull-up is only for bench debugging.
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports i2c_scl]
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports i2c_sda]
