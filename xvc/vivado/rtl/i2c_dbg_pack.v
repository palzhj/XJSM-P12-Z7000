// i2c_dbg_pack.v — scan result packing (two probes)
// probe0 (1 bit)  : ack_pulse stretched (for triggering)
// probe1 (31 bit) : {ack_val, scl_in, sda_in, st[3:0], scan_addr[7:0], ack_cnt[7:0], first_ack[7:0]}
`timescale 1ns/1ps
module i2c_dbg_pack (
    input  wire        clk,
    input  wire        rstn,
    input  wire        ack_val,
    input  wire        ack_pulse,
    input  wire        scl_in,
    input  wire        sda_in,
    input  wire [3:0]  st,
    input  wire [7:0]  scan_addr,
    input  wire [7:0]  ack_cnt,
    input  wire [7:0]  first_ack,
    output wire        ack_bit,
    output wire [30:0] rest
);
    reg [11:0] hold;
    always @(posedge clk) begin
        if (!rstn) hold <= 12'd0;
        else if (ack_pulse) hold <= 12'd2000;
        else if (hold != 12'd0) hold <= hold - 12'd1;
    end
    assign ack_bit = (hold != 12'd0);
    assign rest    = {ack_val, scl_in, sda_in, st, scan_addr, ack_cnt, first_ack};
endmodule
