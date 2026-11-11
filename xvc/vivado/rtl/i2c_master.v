// i2c_master.v - minimal I2C master (GPIO style, bit-banged by software)
//
// Registers (AXI4-Lite, base address assigned by the BD):
//   0x00 CTRL   R/W  bit0 = SCL level, bit1 = SDA level (1 = release/high, 0 = pull low)
//   0x04 STATUS R    bit0 = SDA input level, bit1 = SCL input level
//
// The pins are open-drain: output 0 drives low, output 1 is high-impedance (relies on external pull-ups).
// Software can produce any I2C timing by reading/writing these two registers through /dev/mem.
//
// Timing reference (100 kHz): t_HD_STA 4us, t_LOW 4.7us, t_HIGH 4us, t_SU_STO 4us.
// Each AXI access takes about 1us, so software must insert delays itself.
`timescale 1ns / 1ps

module i2c_master #(
    parameter [31:0] BASE = 32'h43C1_0000
) (
    input  wire        clk,
    input  wire        rstn,

    // AXI4-Lite slave
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output wire [1:0]  s_axi_bresp,
    output wire        s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output wire [31:0] s_axi_rdata,
    output wire [1:0]  s_axi_rresp,
    output wire        s_axi_rvalid,
    input  wire        s_axi_rready,

    // I2C pins (open-drain)
    output reg         scl_low,     // 1 = release (high-Z/high), 0 = drive low
    output reg         sda_low,     // same as above
    input  wire        sda_in,
    input  wire        scl_in
);

    reg [31:0] ctrl;
    reg        aw_done, w_done;
    reg [31:0] waddr, wdata;

    assign s_axi_awready = !aw_done;
    assign s_axi_wready  = !w_done;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_rresp   = 2'b00;

    // write channel
    reg s_axi_bvalid_r;
    assign s_axi_bvalid = s_axi_bvalid_r;

    always @(posedge clk) begin
        if (!rstn) begin
            aw_done <= 1'b0; w_done <= 1'b0; s_axi_bvalid_r <= 1'b0;
            waddr <= 32'd0; wdata <= 32'd0; ctrl <= 32'd3;   /* release both lines by default */
        end else begin
            if (s_axi_bvalid_r && s_axi_bready) s_axi_bvalid_r <= 1'b0;
            if (s_axi_awvalid && s_axi_awready) begin waddr <= s_axi_awaddr; aw_done <= 1'b1; end
            if (s_axi_wvalid  && s_axi_wready)  begin wdata <= s_axi_wdata;  w_done  <= 1'b1; end
            if (aw_done && w_done) begin
                if (waddr[3:2] == 2'd0) ctrl <= wdata;
                aw_done <= 1'b0; w_done <= 1'b0; s_axi_bvalid_r <= 1'b1;
            end
        end
    end

    // read channel
    reg [31:0] rdata_r;
    reg        rvalid_r;
    assign s_axi_arready = !rvalid_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_rvalid  = rvalid_r;

    always @(posedge clk) begin
        if (!rstn) begin
            rvalid_r <= 1'b0; rdata_r <= 32'd0;
        end else begin
            if (rvalid_r && s_axi_rready) rvalid_r <= 1'b0;
            if (s_axi_arvalid && s_axi_arready) begin
                case (s_axi_araddr[3:2])
                    2'd0: rdata_r <= ctrl;
                    2'd1: rdata_r <= {30'd0, scl_in, sda_in};
                    default: rdata_r <= 32'd0;
                endcase
                rvalid_r <= 1'b1;
            end
        end
    end

    always @(posedge clk) begin
        if (!rstn) begin
            scl_low <= 1'b0; sda_low <= 1'b0;
        end else begin
            /* ctrl bit = 1 -> release (high-Z/high level), = 0 -> drive low
             * IOBUF T = 1 means high-Z, so the ctrl bit drives T directly here */
            scl_low <= ctrl[0];
            sda_low <= ctrl[1];
        end
    end

endmodule
