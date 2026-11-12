// jtag_ctrl.v - AXI4-Lite -> JTAG controller (register map per XAPP1251)
//
// 0x00 LENGTH      R/W  number of bits to shift
// 0x04 TMS_VECTOR  R/W  bit0 shifted out first
// 0x08 TDI_VECTOR  R/W  bit0 shifted out first
// 0x0C TDO_VECTOR  R/W  bit0 = first sampled bit
// 0x10 CTRL        R/W  bit0 = enable shift (self-clearing), bit1 = free-running TCK (for debug)
// 0x14 DIV         R/W  TCK half period = DIV clk cycles (0 treated as 8)
//
// DMA / bring-up observation registers (read-only, jtag0 is the only DMA engine):
// 0x24 STATUS      RO   {rx_used[15:8], tx_free[7:0]}
// 0x44 DMAW        R/W  words to move: the pop carrying this many makes TLAST
// 0x48 DROP        RO   TDO words discarded because the RX FIFO was full
// 0x4C TVALID_CYC  RO   clocks m_axis_tdo_tvalid was high
// 0x50 TREADY_CYC  RO   clocks m_axis_tdo_tready was high
// 0x54 POP_CYC     RO   clocks a word was actually popped (tvalid & tready)
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

    /* ---- streaming FIFO: 0x1C TXD (write) / 0x20 RXD (read) / 0x24 STATUS ----
     * Depth 128, but the pointers are 8-bit so that write-minus-read gives the
     * occupancy modulo 256. Every array access must therefore mask the pointer
     * to the 7 real address bits: tx_mem[tx_wr] is out of range once tx_wr
     * passes 127. Vivado truncates the index silently so the hardware happens
     * to do the right thing, but simulation reads X, which is how this was
     * caught - keep the explicit [6:0].
     */
    reg [31:0] tx_mem [0:127];
    (* INIT = 8'h00 *) reg [7:0] tx_wr;
    (* INIT = 8'h00 *) reg [7:0] tx_rd;
    reg [31:0] rx_mem [0:127];
    (* INIT = 8'h00 *) reg [7:0] rx_wr;
    (* INIT = 8'h00 *) reg [7:0] rx_rd;
    reg        tx_pop, rx_push;    /* internal single-cycle pulses (not AXIS handshakes) */
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

    /* ---- m_axis_tdo handshake counters (which side of the stream stops first) ----
     * Free-running from reset: 100 MHz FCLK0 wraps 32 bits in ~43 s, so software
     * takes two snapshots and compares deltas instead of reading absolutes.
     *   0x4C dbg_tvalid_cyc  clocks m_axis_tdo_tvalid was high (engine has a word)
     *   0x50 dbg_tready_cyc  clocks m_axis_tdo_tready was high (S2MM will take it)
     *   0x54 dbg_pop_cyc     clocks axis_pop fired             (word really moved)
     */
    (* INIT = 32'h0 *) reg [31:0] dbg_tvalid_cyc;
    (* INIT = 32'h0 *) reg [31:0] dbg_tready_cyc;
    (* INIT = 32'h0 *) reg [31:0] dbg_pop_cyc;
    reg        ctrl_free;
    reg        fifo_clr;     /* TAP block requests FIFO flush (pulse) */
    reg [31:0] go_seq;

    // ---- AXI write channel ----
    reg        aw_done, w_done;
    reg [31:0] waddr, wdata;

    /* ---- FIFO port arbitration (AXI-Lite register access vs AXI-Stream) ----
     * A word moves on the SAME clock as the handshake that moved it. This is not
     * cosmetic: the AXI-Stream peer samples tvalid/tready combinationally, so if
     * tx_wr / rx_rd only advanced a couple of clocks later the FIFO would keep
     * advertising the old occupancy, the same TDO word would be popped more than
     * once, and the modulo-256 pointers would wrap into a bogus "255 words
     * queued" state that never drains. That was the observed ~1917-word stall.
     */
    wire axis_push  = dma_en && s_axis_tdi_tvalid && !tx_full;
    wire axis_pop   = dma_en && m_axis_tdo_tready && !rx_empty;
    wire axi_txd_wr = aw_done && w_done && (waddr[7:2] == 6'd7) && !tx_full && !axis_push;
    wire axi_rxd_rd = s_axi_arvalid && s_axi_arready && (s_axi_araddr[7:2] == 6'd8) && !rx_empty;
    wire tx_push    = axis_push || axi_txd_wr;   /* one word into the TX FIFO  */
    wire rx_pop     = axis_pop  || axi_rxd_rd;   /* one word out of the RX FIFO */

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
        end else begin
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;


            if (s_axi_awvalid && s_axi_awready) begin
                waddr <= s_axi_awaddr; aw_done <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata <= s_axi_wdata; w_done <= 1'b1;
            end

            if (aw_done && w_done) begin
                case (waddr[7:2])
                    6'd0: len_q <= wdata;
                    6'd1: tms_q <= wdata;
                    6'd2: tdi_q <= wdata;
                    6'd3: ;                       // TDO is read-only
                    6'd15: chsel_q <= wdata[3:0];   /* 0x3C broadcast TDO source */
                    6'd16: bcmask_q <= wdata[11:0]; /* 0x40 broadcast channel mask */
                    6'd17: begin                    /* 0x44 DMA word count (arms TLAST) */
                        dmaw_q    <= wdata;
                        dmaw_left <= wdata;
                    end
                    6'd4: begin
                        ctrl_q <= wdata;
                        if (wdata[0]) go_seq <= go_seq + 32'd1;   // start one shift
                        ctrl_free <= wdata[1];
                    end
                    6'd5: div_q <= wdata;         // 0x14 DIV
                    6'd7: ;                       // 0x1C TXD: written by the FIFO pointer block
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
            s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0; s_axi_rresp <= 2'b00;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
            /* The RX FIFO read pointer moves combinationally on rx_pop (see the
             * handshake wires above): an AXI RXD read and an m_axis pop are the
             * same slot, and the pointer must advance in the read cycle so that
             * rx_mem[rx_rd] below still returns the word being handed over. */

            if (s_axi_arvalid && s_axi_arready) begin
                case (s_axi_araddr[7:2])
                    6'd0: s_axi_rdata <= len_q;
                    6'd1: s_axi_rdata <= tms_q;
                    6'd2: s_axi_rdata <= tdi_q;
                    6'd3: s_axi_rdata <= tdo_q;
                    6'd4: s_axi_rdata <= {30'd0, ctrl_free, (running | (go_seq != seen_seq))};
                    6'd5: s_axi_rdata <= {8'hA7, 22'd0, busy, 1'b0};   /* 0xA7 = FIFO version */
                    6'd6: s_axi_rdata <= div_q;
                    6'd8: s_axi_rdata <= rx_mem[rx_rd[6:0]];               /* 0x20 RXD */
                    6'd9: s_axi_rdata <= {16'd0, rx_used8, tx_free8};  /* 0x24 STATUS */
                    6'd10: s_axi_rdata <= stream_cnt;                  /* 0x28 completed chunk count */
                    6'd15: s_axi_rdata <= {28'd0, chsel_q};            /* 0x3C broadcast TDO source */
                    6'd16: s_axi_rdata <= {20'd0, bcmask_q};           /* 0x40 broadcast mask */
                    6'd17: s_axi_rdata <= dmaw_left;                   /* 0x44 words left */
                    6'd18: s_axi_rdata <= stream_drop;                 /* 0x48 drop count */
                    6'd19: s_axi_rdata <= dbg_tvalid_cyc;              /* 0x4C tvalid cycles */
                    6'd20: s_axi_rdata <= dbg_tready_cyc;              /* 0x50 tready cycles */
                    6'd21: s_axi_rdata <= dbg_pop_cyc;                 /* 0x54 pop cycles */
                    6'd13: s_axi_rdata <= stream_start_cnt;            /* 0x34 start count */
                    6'd14: s_axi_rdata <= {go_seq[15:0], seen_seq[15:0]}; /* 0x38 sequence number */
                    6'd11: s_axi_rdata <= {16'd0, ph};                 /* 0x2C phase counter */
                    6'd12: s_axi_rdata <= {22'd0, state, bits, stream_chunk, busy};
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
            stream_drop  <= 32'd0;
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
                        sh_tdi       <= tx_mem[tx_rd[6:0]];
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
                                    rx_mem[rx_wr[6:0]] <= tdo_q;
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
     * s_axis_tdi pushes TDI words into the TX FIFO (same slot the AXI TXD
     * register uses), m_axis_tdo pops TDO words out of the RX FIFO (same slot
     * the AXI RXD register uses). axis_push / axis_pop are declared with the
     * handshake wires near the top so the pointer block sees them directly.
     */
    assign s_axis_tdi_tready = dma_en && !tx_full;
    assign m_axis_tdo_tdata  = rx_mem[rx_rd[6:0]];
    assign m_axis_tdo_tvalid = dma_en && !rx_empty;
    /* S2MM needs TLAST to know where a transfer ends. Software loads the word
     * count into 0x44 first; the last word of the run carries TLAST. */
    assign m_axis_tdo_tlast  = dma_en && !rx_empty && (dmaw_left == 32'd1);
    /* dmaw_left is decremented in the AXI write always block below, which is
     * also where it is loaded - one block, one driver. */

    /* ---- unified FIFO pointer management: single driver + software clear ----
     * The transfer cycle is the cycle the pointer moves: tx_push / rx_pop are
     * combinationally true in the same clock as the handshake, so the FIFO
     * never advertises an occupancy it no longer has. tx_mem lives here (one
     * driver) and takes its data from whichever port won the cycle.
     */
    always @(posedge clk) begin
        if (!rstn || ctrl_q[2]) begin
            tx_wr <= 8'd0; tx_rd <= 8'd0; rx_wr <= 8'd0; rx_rd <= 8'd0;
        end else begin
            if (tx_push) begin
                tx_mem[tx_wr[6:0]] <= axis_push ? s_axis_tdi_tdata : wdata;
                tx_wr         <= tx_wr + 8'd1;
            end
            if (tx_pop)  tx_rd <= tx_rd + 8'd1;
            if (rx_push) rx_wr <= rx_wr + 8'd1;
            if (rx_pop)  rx_rd <= rx_rd + 8'd1;
            if (fifo_clr) begin                  /* broadcast takeover: flush both FIFOs */
                tx_rd <= tx_wr;
                rx_rd <= rx_wr;
            end
        end
    end

    /* ---- handshake counters: one driver each, free-running ----
     * Deliberately NOT cleared by ctrl_q[2] (the FIFO flush) so a run can be
     * bracketed by two software snapshots. Compare deltas:
     *   tvalid climbing, tready flat  -> S2MM stopped accepting
     *   tready climbing, tvalid flat  -> the shift engine stopped producing
     *   both climbing, pop flat       -> the handshake itself is broken
     *   all three flat                -> mutual deadlock (engine idle, S2MM waiting)
     */
    always @(posedge clk) begin
        if (!rstn) begin
            dbg_tvalid_cyc <= 32'd0;
            dbg_tready_cyc <= 32'd0;
            dbg_pop_cyc    <= 32'd0;
        end else begin
            if (m_axis_tdo_tvalid) dbg_tvalid_cyc <= dbg_tvalid_cyc + 32'd1;
            if (m_axis_tdo_tready) dbg_tready_cyc <= dbg_tready_cyc + 32'd1;
            if (axis_pop)          dbg_pop_cyc    <= dbg_pop_cyc    + 32'd1;
        end
    end

endmodule
