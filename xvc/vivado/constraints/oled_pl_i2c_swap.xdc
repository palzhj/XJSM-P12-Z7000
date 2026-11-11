# Swapped variant: assumes the module has SCL/SDA reversed
set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports i2c_scl]
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33 PULLTYPE PULLUP} [get_ports i2c_sda]
