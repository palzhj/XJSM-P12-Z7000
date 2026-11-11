// jtag_bcast_regs.v — broadcast control register block (standalone AXI-Lite slave)
//
// Completely decoupled from jtag_ctrl: jtag_ctrl stays as-is, broadcast control is centralized here.
//
// Register map (address 0x43CD0000, 64 KB window):
//   0x00  CTRL    bit0 = bcast_en (1 = broadcast mode)
//   0x04  BCMASK  [11:0] channels participating in broadcast
//   0x08  CHSEL   [3:0]  which TDO lane to read back during broadcast
//   0x0C  TAG     [31:0] read-only, 0xB7000000 (for identification)
//   0x10  STATUS  [11:0] read-only, currently effective mask (all selected when BCMASK=0)
//
// Address decoding uses equality comparison (not case) to avoid width issues with high addresses like 0x40.

module jtag_bcast_regs #(
    parameter [31:0] TAG_VAL = 32'hB7000000
)(
    input  wire        clk,
    input  wire        rstn,

    /* AXI4-Lite slave interface */
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output wire        s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output wire        s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output wire        s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    /* control signals to repeater/mux */
    output reg         bcast_en,
    output reg  [11:0] bcmask,
    output reg  [3:0]  chsel,
    output wire [11:0] bcmask_eff      /* treated as all-selected when 0 */
);

    assign s_axi_awready = 1'b1;
    assign s_axi_wready  = 1'b1;
    assign s_axi_arready = !s_axi_rvalid;

    /* write address/data capture (aw and w may arrive in different cycles) */
    reg [31:0] waddr_q, wdata_q;
    reg        aw_hit, w_hit;

    always @(posedge clk) begin
        if (!rstn) begin
            waddr_q <= 32'd0; wdata_q <= 32'd0;
            aw_hit  <= 1'b0;  w_hit   <= 1'b0;
            s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
            bcast_en <= 1'b0;
            bcmask   <= 12'hFFF;
            chsel    <= 4'd0;
        end else begin
            if (s_axi_awvalid && s_axi_awready && !aw_hit) begin
                waddr_q <= s_axi_awaddr; aw_hit <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready && !w_hit) begin
                wdata_q <= s_axi_wdata; w_hit <= 1'b1;
            end

            if (aw_hit && w_hit) begin
                /* decode with equality comparison (addr[7:2] is the register index) */
                if (waddr_q[7:2] == 6'd0)                     /* 0x00 CTRL   */
                    bcast_en <= wdata_q[0];
                else if (waddr_q[7:2] == 6'd1)                /* 0x04 BCMASK */
                    bcmask   <= wdata_q[11:0];
                else if (waddr_q[7:2] == 6'd2)                /* 0x08 CHSEL  */
                    chsel    <= wdata_q[3:0];

                aw_hit <= 1'b0; w_hit <= 1'b0;
                s_axi_bvalid <= 1'b1;
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end

            /* read channel */
            if (s_axi_arvalid && s_axi_arready) begin
                if      (s_axi_araddr[7:2] == 6'd0) s_axi_rdata <= {31'd0, bcast_en};
                else if (s_axi_araddr[7:2] == 6'd1) s_axi_rdata <= {20'd0, bcmask};
                else if (s_axi_araddr[7:2] == 6'd2) s_axi_rdata <= {28'd0, chsel};
                else if (s_axi_araddr[7:2] == 6'd3) s_axi_rdata <= TAG_VAL;
                else if (s_axi_araddr[7:2] == 6'd4) s_axi_rdata <= {20'd0, bcmask_eff};
                else                                s_axi_rdata <= 32'd0;
                s_axi_rvalid <= 1'b1;
            end else if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end

    /* when the mask is 0 treat it as "all selected" so broadcast always reaches every channel */
    assign bcmask_eff = (bcmask == 12'd0) ? 12'hFFF : bcmask;

endmodule
