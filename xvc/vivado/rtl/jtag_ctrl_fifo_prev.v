// jtag_ctrl.v - AXI4-Lite -> JTAG controller (register map per XAPP1251)
//
// 0x00 LENGTH      R/W  number of bits to shift
// 0x04 TMS_VECTOR  R/W  bit0 shifted out first
// 0x08 TDI_VECTOR  R/W  bit0 shifted out first
// 0x0C TDO_VECTOR  R/W  bit0 = first sampled bit
// 0x10 CTRL        R/W  bit0 = enable shift (self-clearing), bit1 = free-running TCK (for debug)
// 0x14 DIV         R/W  TCK half period = DIV clk cycles (0 treated as 8)
module jtag_ctrl #(
    parameter integer DIV_DEFAULT = 8
) (
    input  wire        clk,
    input  wire        rstn,

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

    output reg         tck,
    output reg         tms,
    output reg         tdi,
    input  wire        tdo,
    output wire        busy,
    output wire [31:0] dbg          /* debug observation: see assign dbg */
);

    localparam [1:0] IDLE = 2'd0, LOAD = 2'd1, HIGH = 2'd2, LOW = 2'd3;

    reg [31:0] len_q, tms_q, tdi_q, tdo_q, div_q;

    /* ---- streaming FIFO: 0x1C TXD (write) / 0x20 RXD (read) / 0x24 STATUS ---- */
    reg [31:0] tx_mem [0:127];
    (* INIT = 8'h00 *) reg [7:0] tx_wr, tx_rd;
    reg [31:0] rx_mem [0:127];
    (* INIT = 8'h00 *) reg [7:0] rx_wr, rx_rd;
    /* underflow/overflow protection: crossed pointers count as empty/full so tx_used cannot become huge */
    wire       tx_under = (tx_rd > tx_wr);        /* underflow: read pointer beyond write pointer */
    wire       rx_under = (rx_rd > rx_wr);
    wire [7:0] tx_diff  = tx_wr - tx_rd;
    wire [7:0] rx_diff  = rx_wr - rx_rd;
    wire [8:0] tx_used  = tx_under ? 9'd0 : {1'b0, tx_diff};
    wire [8:0] rx_used  = rx_under ? 9'd0 : {1'b0, rx_diff};
    wire       tx_empty = (tx_used == 9'd0);
    wire       tx_full  = (tx_used >= 9'd128);
    wire       rx_full  = (rx_used >= 9'd128);
    wire       rx_empty = (rx_used == 9'd0);
    wire [8:0] tx_free9 = tx_full ? 9'd0 : (9'd128 - tx_used);
    wire [7:0] tx_free8 = tx_free9[7:0];
    wire [7:0] rx_used8 = rx_used[7:0];
    reg        stream_chunk;
    (* INIT = 32'h0 *) reg [31:0] stream_cnt;
    reg        ctrl_free;
    reg [31:0] go_seq;

    // ---- AXI write channel ----
    reg        aw_done, w_done;
    reg [31:0] waddr, wdata;

    assign s_axi_awready = !aw_done;
    assign s_axi_wready  = !w_done;

    always @(posedge clk) begin
        if (!rstn) begin
            aw_done <= 1'b0; w_done <= 1'b0;
            s_axi_bvalid <= 1'b0; s_axi_bresp <= 2'b00;
            waddr <= 32'd0; wdata <= 32'd0;
            len_q <= 32'd0; tms_q <= 32'd0; tdi_q <= 32'd0;
            div_q <= DIV_DEFAULT[31:0];
            ctrl_free <= 1'b0; go_seq <= 32'd0;
            tx_wr <= 8'd0; tx_rd <= 8'd0; rx_wr <= 8'd0; rx_rd <= 8'd0;
            stream_chunk <= 1'b0; stream_cnt <= 32'd0;
        end else begin
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
            if (rx_under) rx_rd <= rx_wr;      /* self-heal (rx_rd is driven only in the read block) */

            if (s_axi_awvalid && s_axi_awready) begin
                waddr <= s_axi_awaddr; aw_done <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata <= s_axi_wdata; w_done <= 1'b1;
            end

            if (aw_done && w_done) begin
                case (waddr[5:2])
                    4'd0: len_q <= wdata;
                    4'd1: tms_q <= wdata;
                    4'd2: tdi_q <= wdata;
                    4'd3: ;                       // TDO is read-only
                    4'd4: begin
                        if (wdata[0]) go_seq <= go_seq + 32'd1;   // start one shift
                        ctrl_free <= wdata[1];
                    end
                    4'd5: div_q <= wdata;         // 0x14 DIV
                    4'd7: begin                   // 0x1C TXD (discard when full)
                        if (!tx_full) begin
                            tx_mem[tx_wr] <= wdata;
                            tx_wr <= tx_wr + 8'd1;
                        end
                    end
                    default: ;
                endcase
                aw_done <= 1'b0; w_done <= 1'b0; s_axi_bvalid <= 1'b1;
            end
        end
    end

    // ---- AXI read channel ----
    assign s_axi_arready = !s_axi_rvalid;
    always @(posedge clk) begin
        if (!rstn) begin
            s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0; s_axi_rresp <= 2'b00;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
            if (s_axi_arvalid && s_axi_arready && (s_axi_araddr[5:2] == 4'd8) && !rx_empty)
                rx_rd <= rx_rd + 8'd1;

            if (s_axi_arvalid && s_axi_arready) begin
                case (s_axi_araddr[5:2])
                    4'd0: s_axi_rdata <= len_q;
                    4'd1: s_axi_rdata <= tms_q;
                    4'd2: s_axi_rdata <= tdi_q;
                    4'd3: s_axi_rdata <= tdo_q;
                    4'd4: s_axi_rdata <= {30'd0, ctrl_free, (running | (go_seq != seen_seq))};
                    4'd5: s_axi_rdata <= {8'hA7, 22'd0, busy, 1'b0};   /* 0xA7 = FIFO version */
                    4'd6: s_axi_rdata <= div_q;
                    4'd8: s_axi_rdata <= rx_mem[rx_rd];               /* 0x20 RXD */
                    4'd9: s_axi_rdata <= {16'd0, rx_used8, tx_free8};  /* 0x24 STATUS */
                    4'd10: s_axi_rdata <= stream_cnt;                  /* 0x28 completed chunk count */
                    4'd11: s_axi_rdata <= {16'd0, ph};                 /* 0x2C phase counter */
                    4'd12: s_axi_rdata <= {22'd0, state, bits, stream_chunk, busy};
                                                                       /* 0x30 {state[1:0],bits[5:0],stream_chunk,busy} */
                    default: s_axi_rdata <= 32'd0;
                endcase
                s_axi_rvalid <= 1'b1;
            end
        end
    end

    // ---- shift engine: single phase counter, explicit TCK edges (exactly 1 rising edge per bit) ----
    localparam S_IDLE = 1'b0, S_RUN = 1'b1;

    reg        state;
    reg [15:0] ph;              // 0 .. 2*div-1
    reg [5:0]  bits;            // remaining bit count
    reg [31:0] sh_tms, sh_tdi, sh_tdo;
    reg        running;
    reg [31:0] seen_seq;

    assign busy = running;

    /* debug packing (for ILA observation)
     * [31:24] stream_cnt[7:0]   [23:16] tx_wr      [15:8] tx_rd
     * [7:6]   state             [5:0]   {ph[2:0], bits[5:0]} not enough, use low ph bits instead
     *
     * actual layout:
     *   [31:24] stream_cnt[7:0]
     *   [23:16] tx_wr[7:0]
     *   [15: 8] tx_rd[7:0]
     *   [ 7: 6] state[1:0]
     *   [ 5: 0] {stream_chunk, busy, ph[3:0]}
     * bits and rx_wr are observed via the 0x24/0x28 register bypass
     */
    assign dbg = {stream_cnt[7:0], tx_wr, tx_rd, state, stream_chunk, busy, ph[3:0]};

    wire [15:0] div   = (div_q[15:0] == 16'd0) ? 16'd8 : div_q[15:0];
    wire [15:0] ph_end  = (div << 1) - 16'd1;
    wire [15:0] ph_rise = div;
    wire [15:0] ph_samp = div + (div >> 1);

    always @(posedge clk) begin
        if (!rstn) begin
            state <= S_IDLE; tck <= 1'b0; tms <= 1'b0; tdi <= 1'b0;
            tdo_q <= 32'd0; running <= 1'b0; seen_seq <= 32'd0;
            sh_tms <= 32'd0; sh_tdi <= 32'd0; sh_tdo <= 32'd0;
            bits <= 6'd0; ph <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    tck <= 1'b0;
                    if (tx_under) begin
                        tx_rd <= tx_wr;            /* underflow self-heal */
                    end else if ((go_seq == seen_seq) && !tx_empty && !rx_full) begin
                        running      <= 1'b1;
                        stream_chunk <= 1'b1;
                        sh_tms       <= 32'd0;
                        sh_tdi       <= tx_mem[tx_rd];
                        sh_tdo       <= 32'd0;
                        bits         <= 6'd32;
                        ph           <= 16'd0;
                        state        <= S_RUN;
                        tx_rd        <= tx_rd + 8'd1;
                    end else if (go_seq != seen_seq) begin
                        seen_seq <= go_seq;
                        running  <= 1'b1;
                        sh_tms   <= tms_q;
                        sh_tdi   <= tdi_q;
                        sh_tdo   <= 32'd0;
                        bits     <= (len_q == 0) ? 6'd1 : len_q[5:0];
                        ph       <= 16'd0;
                        state    <= S_RUN;
                        stream_chunk <= 1'b0;
                    end
                end

                S_RUN: begin
                    if (ph == 16'd0) begin
                        /* new bit: set up TMS/TDI first, keep TCK low */
                        tms <= sh_tms[0];
                        tdi <= sh_tdi[0];
                        tck <= 1'b0;
                    end
                    if (ph == ph_rise)
                        tck <= 1'b1;                 /* the only rising edge */
                    if (ph == ph_samp) begin
                        sh_tdo <= {tdo, sh_tdo[31:1]};
                        if (bits == 6'd1)
                            tdo_q <= {tdo, sh_tdo[31:1]};
                    end
                    if (ph == ph_end) begin
                        tck <= 1'b0;                 /* falling edge */
                        ph  <= 16'd0;
                        if (bits == 6'd1) begin
                            running <= 1'b0;
                            state   <= S_IDLE;
                            if (stream_chunk) begin
                                rx_mem[rx_wr] <= tdo_q;
                                rx_wr         <= rx_wr + 8'd1;
                                stream_cnt    <= stream_cnt + 32'd1;
                            end
                        end else begin
                            bits   <= bits - 6'd1;
                            sh_tms <= sh_tms >> 1;
                            sh_tdi <= sh_tdi >> 1;
                        end
                    end else begin
                        ph <= ph + 16'd1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
