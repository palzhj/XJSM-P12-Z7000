// i2c_emio.v - tri-state buffers for a PS7 I2C controller routed through EMIO.
//
// The PS7 EMIO I2C port exposes separate I/O/T signals (T = 1 -> input/high-Z),
// which is exactly the IOBUF primitive's T semantics.  Put this module in the
// block design and connect its inout pins to the package pins.
//
// Direction of the *_i ports is OUTPUT (buffer -> PS7 input), *_o and *_t are
// INPUT (PS7 -> buffer).  This is the usual EMIO convention and is easy to get
// backwards; check with `get_bd_pins -of_objects <module>`.
//
// Zynq side (PS7 EMIO)              Board side
//   I2C1_SCL_I  <-- scl_i           i2c_scl  (open drain, 4.7k pull-up to 3.3V)
//   I2C1_SCL_O  --> scl_o
//   I2C1_SCL_T  --> scl_t
//   I2C1_SDA_I  <-- sda_i           i2c_sda  (open drain, 4.7k pull-up to 3.3V)
//   I2C1_SDA_O  --> sda_o
//   I2C1_SDA_T  --> sda_t
`timescale 1ns / 1ps

module i2c_emio (
    output wire scl_i,
    input  wire scl_o,
    input  wire scl_t,
    output wire sda_i,
    input  wire sda_o,
    input  wire sda_t,
    inout  wire i2c_scl,
    inout  wire i2c_sda
);

    IOBUF scl_buf (
        .IO (i2c_scl),
        .I  (scl_o),
        .O  (scl_i),
        .T  (scl_t)
    );

    IOBUF sda_buf (
        .IO (i2c_sda),
        .I  (sda_o),
        .O  (sda_i),
        .T  (sda_t)
    );

endmodule
