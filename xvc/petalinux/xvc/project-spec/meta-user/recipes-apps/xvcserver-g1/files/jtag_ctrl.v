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

    /* ---- DMA streaming ports (CPU-free bulk transfer) ----
     * When dma_en = 1 the TX FIFO is fed from s_axis_tdi and the RX FIFO is
     * drained into m_axis_tdo, so a plain AXI DMA can move a bitstream between
     * DDR and the shift engine without the CPU touching a register per word.
     * The TAP still forces TMS=0 for these chunks, so this path is for the
     * all-zero-TMS bulk phase of a configuration load.
     */
    input  wire [31:0] s_axis_tdi_tdata,
    input  wire        s_axis_tdi_tvalid,
    output wire        s_axis_tdi_tready,
    output wire [31:0] m_axis_tdo_tdata,
    output wire        m_axis_tdo_tvalid,
    output wire        m_axis_tdo_tlast,
    input  wire        m_axis_tdo_tready,
    input  wire        dma_en,

    output reg         tck,
    output reg         tms,
    output reg         tdi,
    input  wire        tdo,
    input  wire        bcast_sel,   /* 1 = this channel currently follows broadcast (provided by repeater) */
    output wire        busy,
    output wire [31:0] dbg,         /* debug observation */
    output wire [3:0]  chsel        /* channel select output */
);

    localparam [1:0] IDLE = 2'd0, LOAD = 2'd1, HIGH = 2'd2, LOW = 2'd3;

    reg [31:0] len_q, tms_q, tdi_q, tdo_q, div_q;
    reg [31:0] ctrl_q;
    reg [3:0]  chsel_q;   /* 12-channel select (broadcast TDO source) */
    reg [11:0] bcmask_q;  /* broadcast channel mask (kept as-is; actual control in jtag_bcast_regs) */                 /* CTRL shadow register (bit2 = FIFO clear) */

    /* ---- streaming FIFO: 0x1C TXD (write) / 0x20 RXD (read) / 0x24 STATUS ---- */
    reg [31:0] tx_mem [0:127];
    (* INIT = 8'h00 *) reg [7:0] tx_wr;
    (* INIT = 8'h00 *) reg [7:0] tx_rd;
    reg [31:0] rx_mem [0:127];
    (* INIT = 8'h00 *) reg [7:0] rx_wr;
    (* INIT = 8'h00 *) reg [7:0] rx_rd;
    reg        tx_push, tx_pop, rx_push, rx_pop;   /* single-cycle pulses */
    /* modulo-256 pointers: write minus read gives occupancy (depth 128, full guards against overflow) */
    wire [7:0] tx_diff  = tx_wr - tx_rd;
    wire [7:0] rx_diff  = rx_wr - rx_rd;
    wire       tx_empty = (tx_diff == 8'd0);
    wire       tx_full  = (tx_diff >= 8'd128);
    wire       rx_empty = (rx_diff == 8'd0);
    /* Leave one slot of headroom: a chunk that is already running when the FIFO
     * looks nearly full still pushes its TDO word on completion, so the guard
     * must trigger one word early. Without this the observed occupancy reached
     * 129 in a 128-entry FIFO, the engine stalled, TX filled behind it and the
     * whole DMA pipeline deadlocked. */
    wire       rx_full  = (rx_diff >= 8'd127);
    wire [7:0] tx_free8 = tx_full ? 8'd0 : (8'd128 - tx_diff);
    wire [7:0] rx_used8 = rx_diff;
    reg [31:0] dmaw_q;       /* 0x44: number of words to move in this DMA run */
    reg [31:0] dmaw_left;    /* decremented on every m_axis pop */
    reg        stream_chunk;
    (* INIT = 32'h0 *) reg [31:0] stream_cnt;
    (* INIT = 32'h0 *) reg [31:0] stream_start_cnt;
    (* INIT = 32'h0 *) reg [31:0] stream_drop;   /* words lost to a full RX FIFO */
    reg        ctrl_free;
    reg        fifo_clr;     /* TAP block requests FIFO flush (pulse) */
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
            ctrl_free <= 1'b0; go_seq <= 32'd0; ctrl_q <= 32'd0; chsel_q <= 4'd0; bcmask_q <= 12'hFFF;
            tx_push <= 1'b0;
        end else begin
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
            tx_push <= 1'b0;                      /* default clear (every clock) */


            if (s_axi_awvalid && s_axi_awready) begin
                waddr <= s_axi_awaddr; aw_done <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata <= s_axi_wdata; w_done <= 1'b1;
            end

            /* DMA: an AXI-Stream word enters the TX FIFO exactly like an AXI TXD
             * write - but it must be serviced on EVERY clock, not only when an
             * AXI write completes, so it lives outside the aw_done/w_done branch. */
            if (axis_push) begin
                tx_mem[tx_wr] <= s_axis_tdi_tdata;
                tx_push       <= 1'b1;
            end

            if (aw_done && w_done) begin
                case (waddr[7:2])
                    4'd0: len_q <= wdata;
                    4'd1: tms_q <= wdata;
                    4'd2: tdi_q <= wdata;
                    4'd3: ;                       // TDO is read-only
                    4'd15: chsel_q <= wdata[3:0];   /* 0x3C broadcast TDO source */
                    6'd16: bcmask_q <= wdata[11:0]; /* 0x40 broadcast channel mask */
                    6'd17: begin                    /* 0x44 DMA word count (arms TLAST) */
                        dmaw_q    <= wdata;
                        dmaw_left <= wdata;
                    end
                    4'd4: begin
                        ctrl_q <= wdata;
                        if (wdata[0]) go_seq <= go_seq + 32'd1;   // start one shift
                        ctrl_free <= wdata[1];
                    end
                    4'd5: div_q <= wdata;         // 0x14 DIV
                    4'd7: begin                   // 0x1C TXD (discard when full)
                        if (!tx_full && !axis_push) begin
                            tx_mem[tx_wr] <= wdata;
                            tx_push <= 1'b1;
                        end
                    end
                    default: ;
                endcase
                aw_done <= 1'b0; w_done <= 1'b0; s_axi_bvalid <= 1'b1;
            end

            /* every m_axis pop consumes one word of the DMA run (every clock) */
            if (axis_pop && dmaw_left != 32'd0)
                dmaw_left <= dmaw_left - 32'd1;
        end
    end

    // ---- AXI read channel ----
    assign s_axi_arready = !s_axi_rvalid;
    always @(posedge clk) begin
        if (!rstn) begin
            s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0; s_axi_rresp <= 2'b00; rx_pop <= 1'b0;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
            /* DMA drains the RX FIFO through m_axis; an AXI RXD read does the same */
            rx_pop <= axis_pop;
            if (s_axi_arvalid && s_axi_arready && (s_axi_araddr[5:2] == 4'd8) && !rx_empty)
                rx_pop <= 1'b1;

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
                    4'd15: s_axi_rdata <= {28'd0, chsel_q};            /* 0x3C broadcast TDO source */
                    6'd16: s_axi_rdata <= {20'd0, bcmask_q};           /* 0x40 broadcast mask */
                    6'd17: s_axi_rdata <= dmaw_left;                   /* 0x44 words left */
                    6'd18: s_axi_rdata <= stream_drop;                 /* 0x48 drop count */
                    4'd13: s_axi_rdata <= stream_start_cnt;            /* 0x34 start count */
                    4'd14: s_axi_rdata <= {go_seq[15:0], seen_seq[15:0]}; /* 0x38 sequence number */
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
    localparam [1:0] S_IDLE = 2'd0, S_RUN = 2'd1, S_BC = 2'd3;

    reg [1:0]  state;
    reg [15:0] ph;              // 0 .. 2*div-1
    reg [5:0]  bits;            // remaining bit count
    reg [31:0] sh_tms, sh_tdi, sh_tdo;
    reg        running;
    reg [31:0] seen_seq;

    assign busy = running;
    assign chsel = chsel_q;



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
            stream_chunk <= 1'b0; stream_cnt <= 32'd0; stream_start_cnt <= 32'd0;
            tx_pop <= 1'b0; rx_push <= 1'b0; fifo_clr <= 1'b0;
        end else if (bcast_sel && state != S_RUN) begin
            /* broadcast selected this channel (not shifting): stop immediately, clear internal
             * registers and FIFO pointers, and enter S_BC. The pins are switched to the
             * broadcast engine by the repeater; this engine no longer drives them. */
            tck     <= 1'b0;
            tms     <= 1'b0;
            tdi     <= 1'b0;
            running <= 1'b0;
            bits    <= 6'd0;
            ph      <= 16'd0;
            sh_tms  <= 32'd0;
            sh_tdi  <= 32'd0;
            sh_tdo  <= 32'd0;
            tdo_q   <= 32'd0;
            stream_chunk <= 1'b0;
            tx_pop  <= 1'b0; rx_push <= 1'b0;
            /* flush both FIFOs (the client has been disconnected by the server side, old data is meaningless) */
            fifo_clr <= 1'b1;
            /* consume pending shift requests so old data is not resent right after leaving S_BC */
            seen_seq <= go_seq;
            state   <= S_BC;
        end else begin
            tx_pop <= 1'b0; rx_push <= 1'b0;
            fifo_clr <= 1'b0;
            case (state)
                S_BC: begin
                    /* held while broadcast takes over: do not drive pins, clear leftover state.
                     * once bcast_sel is deasserted go straight back to IDLE (do not resume the
                     * interrupted shift). */
                    tck     <= 1'b0;
                    running <= 1'b0;
                    bits    <= 6'd0;
                    ph      <= 16'd0;
                    sh_tms  <= 32'd0;
                    sh_tdi  <= 32'd0;
                    stream_chunk <= 1'b0;
                    fifo_clr <= 1'b1;      /* keep FIFO empty continuously */
                    seen_seq <= go_seq;    /* keep consuming pending requests */
                    if (!bcast_sel) state <= S_IDLE;
                end
                S_IDLE: begin
                    tck <= 1'b0;
                    if (!tx_empty && !rx_full) begin
                        running      <= 1'b1;
                        stream_chunk <= 1'b1;
                        sh_tms       <= 32'd0;
                        sh_tdi       <= tx_mem[tx_rd];
                        sh_tdo       <= 32'd0;
                        bits         <= 6'd32;
                        ph           <= 16'd0;
                        state        <= S_RUN;
                        tx_pop       <= 1'b1;
                        stream_start_cnt <= stream_start_cnt + 32'd1;
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
                        if (bcast_sel) begin
                            /* this bit has just completed (full TCK falling edge), hand over to broadcast */
                            running <= 1'b0;
                            bits    <= 6'd0;
                            sh_tms  <= 32'd0;
                            sh_tdi  <= 32'd0;
                            sh_tdo  <= 32'd0;
                            tdo_q   <= 32'd0;
                            stream_chunk <= 1'b0;
                            fifo_clr <= 1'b1;
                            seen_seq <= go_seq;
                            state   <= S_BC;
                        end else if (bits == 6'd1) begin
                            running <= 1'b0;
                            state   <= S_IDLE;
                            if (stream_chunk) begin
                                /* Never write past a full FIFO: overwriting an
                                 * unread slot corrupts rx_diff (it reached 130 in
                                 * a 128-entry FIFO), which then looks permanently
                                 * full and deadlocks the whole pipeline. If the
                                 * consumer is too slow the word is dropped and
                                 * counted in stream_drop instead. */
                                if (!rx_full) begin
                                    rx_mem[rx_wr] <= tdo_q;
                                    rx_push       <= 1'b1;
                                    stream_cnt    <= stream_cnt + 32'd1;
                                end else begin
                                    stream_drop   <= stream_drop + 32'd1;
                                end
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

    /* ---- DMA streaming: AXI-Stream <-> the same FIFOs ----
     * s_axis_tdi pushes TDI words straight into the TX FIFO (same slot the AXI
     * TXD register uses), m_axis_tdo pops TDO words out of the RX FIFO (same
     * slot the AXI RXD register uses). tx_push / rx_pop are single-cycle pulses
     * shared with the AXI path, so the pointer logic below stays untouched.
     */
    wire axis_push = dma_en && s_axis_tdi_tvalid && !tx_full;
    wire axis_pop  = dma_en && m_axis_tdo_tready && !rx_empty;

    assign s_axis_tdi_tready = dma_en && !tx_full;
    assign m_axis_tdo_tdata  = rx_mem[rx_rd];
    assign m_axis_tdo_tvalid = dma_en && !rx_empty;
    /* S2MM needs TLAST to know where a transfer ends. Software loads the word
     * count into 0x44 first; the last word of the run carries TLAST. */
    assign m_axis_tdo_tlast  = dma_en && !rx_empty && (dmaw_left == 32'd1);
    /* dmaw_left is decremented in the AXI write always block below, which is
     * also where it is loaded - one block, one driver. */

    /* tx_push / rx_pop and the FIFO arrays each have a single driver, so the
     * DMA push/pop is merged into the existing AXI always blocks below. */

    /* ---- unified FIFO pointer management: single driver + self-heal + software clear ---- */
    always @(posedge clk) begin
        if (!rstn || ctrl_q[2]) begin
            tx_wr <= 8'd0; tx_rd <= 8'd0; rx_wr <= 8'd0; rx_rd <= 8'd0;
        end else begin
            if (tx_push) tx_wr <= tx_wr + 8'd1;
            if (tx_pop)  tx_rd <= tx_rd + 8'd1;
            if (rx_push) rx_wr <= rx_wr + 8'd1;
            if (rx_pop)  rx_rd <= rx_rd + 8'd1;
            if (fifo_clr) begin                  /* broadcast takeover: flush both FIFOs */
                tx_rd <= tx_wr;
                rx_rd <= rx_wr;
            end
        end
    end

endmodule
