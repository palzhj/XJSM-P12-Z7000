// i2c_od.v - open-drain buffer: converts a "drive low" level into real open-drain pins
//
//   scl_low = 1 -> pin pulled low; scl_low = 0 -> high-Z (relies on external pull-up)
//   scl_in  <- actual pin level
`timescale 1ns / 1ps

module i2c_od (
    input  wire scl_low,
    input  wire sda_low,
    output wire scl_in,
    output wire sda_in,
    inout  wire i2c_scl,
    inout  wire i2c_sda
);

    IOBUF #(.DRIVE(8), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW")) u_scl (
        .O(scl_in), .IO(i2c_scl), .I(1'b0), .T(scl_low));

    IOBUF #(.DRIVE(8), .IOSTANDARD("LVCMOS33"), .SLEW("SLOW")) u_sda (
        .O(sda_in), .IO(i2c_sda), .I(1'b0), .T(sda_low));

endmodule
