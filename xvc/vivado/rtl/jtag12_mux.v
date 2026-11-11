// jtag12_mux.v — 12-channel JTAG pin multiplexing (single engine + channel select, 48 independent ports)
`timescale 1ns/1ps
module jtag12_mux (
    input  wire clk,
    input  wire rstn,
    input  wire tck_i, tms_i, tdi_i,
    output wire tdo_o,
    input  wire [3:0] chsel,
    output wire jtag1_tck,
    output wire jtag1_tms,
    output wire jtag1_tdi,
    output wire jtag2_tck,
    output wire jtag2_tms,
    output wire jtag2_tdi,
    output wire jtag3_tck,
    output wire jtag3_tms,
    output wire jtag3_tdi,
    output wire jtag4_tck,
    output wire jtag4_tms,
    output wire jtag4_tdi,
    output wire jtag5_tck,
    output wire jtag5_tms,
    output wire jtag5_tdi,
    output wire jtag6_tck,
    output wire jtag6_tms,
    output wire jtag6_tdi,
    output wire jtag7_tck,
    output wire jtag7_tms,
    output wire jtag7_tdi,
    output wire jtag8_tck,
    output wire jtag8_tms,
    output wire jtag8_tdi,
    output wire jtag9_tck,
    output wire jtag9_tms,
    output wire jtag9_tdi,
    output wire jtag10_tck,
    output wire jtag10_tms,
    output wire jtag10_tdi,
    output wire jtag11_tck,
    output wire jtag11_tms,
    output wire jtag11_tdi,
    output wire jtag12_tck,
    output wire jtag12_tms,
    output wire jtag12_tdi,
    input  wire jtag1_tdo,
    input  wire jtag2_tdo,
    input  wire jtag3_tdo,
    input  wire jtag4_tdo,
    input  wire jtag5_tdo,
    input  wire jtag6_tdo,
    input  wire jtag7_tdo,
    input  wire jtag8_tdo,
    input  wire jtag9_tdo,
    input  wire jtag10_tdo,
    input  wire jtag11_tdo,
    input  wire jtag12_tdo
);
    wire [11:0] sel = (chsel < 4'd12) ? (12'b1 << chsel) : 12'b0;
    assign jtag1_tck = sel[0] & tck_i;
    assign jtag1_tms = sel[0] & tms_i;
    assign jtag1_tdi = sel[0] & tdi_i;
    assign jtag2_tck = sel[1] & tck_i;
    assign jtag2_tms = sel[1] & tms_i;
    assign jtag2_tdi = sel[1] & tdi_i;
    assign jtag3_tck = sel[2] & tck_i;
    assign jtag3_tms = sel[2] & tms_i;
    assign jtag3_tdi = sel[2] & tdi_i;
    assign jtag4_tck = sel[3] & tck_i;
    assign jtag4_tms = sel[3] & tms_i;
    assign jtag4_tdi = sel[3] & tdi_i;
    assign jtag5_tck = sel[4] & tck_i;
    assign jtag5_tms = sel[4] & tms_i;
    assign jtag5_tdi = sel[4] & tdi_i;
    assign jtag6_tck = sel[5] & tck_i;
    assign jtag6_tms = sel[5] & tms_i;
    assign jtag6_tdi = sel[5] & tdi_i;
    assign jtag7_tck = sel[6] & tck_i;
    assign jtag7_tms = sel[6] & tms_i;
    assign jtag7_tdi = sel[6] & tdi_i;
    assign jtag8_tck = sel[7] & tck_i;
    assign jtag8_tms = sel[7] & tms_i;
    assign jtag8_tdi = sel[7] & tdi_i;
    assign jtag9_tck = sel[8] & tck_i;
    assign jtag9_tms = sel[8] & tms_i;
    assign jtag9_tdi = sel[8] & tdi_i;
    assign jtag10_tck = sel[9] & tck_i;
    assign jtag10_tms = sel[9] & tms_i;
    assign jtag10_tdi = sel[9] & tdi_i;
    assign jtag11_tck = sel[10] & tck_i;
    assign jtag11_tms = sel[10] & tms_i;
    assign jtag11_tdi = sel[10] & tdi_i;
    assign jtag12_tck = sel[11] & tck_i;
    assign jtag12_tms = sel[11] & tms_i;
    assign jtag12_tdi = sel[11] & tdi_i;
    reg tdo_mux;
    always @(*) begin
        case (chsel)
            4'd0: tdo_mux = jtag1_tdo;
            4'd1: tdo_mux = jtag2_tdo;
            4'd2: tdo_mux = jtag3_tdo;
            4'd3: tdo_mux = jtag4_tdo;
            4'd4: tdo_mux = jtag5_tdo;
            4'd5: tdo_mux = jtag6_tdo;
            4'd6: tdo_mux = jtag7_tdo;
            4'd7: tdo_mux = jtag8_tdo;
            4'd8: tdo_mux = jtag9_tdo;
            4'd9: tdo_mux = jtag10_tdo;
            4'd10: tdo_mux = jtag11_tdo;
            4'd11: tdo_mux = jtag12_tdo;
            default: tdo_mux = 1'b1;   /* unconnected channel reads high */
        endcase
    end
    assign tdo_o = tdo_mux;
endmodule
