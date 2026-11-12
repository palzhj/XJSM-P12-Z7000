`timescale 1ns/1ps
// tb_handshake.v - directed check for the 0x4C/0x50/0x54 handshake counters
// and for the [5:2] -> [7:2] read-decode widening (0x4C used to alias 0x0C).
//
//   iverilog -g2012 -o tb_handshake tb_handshake.v ../rtl/jtag_ctrl.v && ./tb_handshake
module tb_handshake;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [31:0] awaddr = 0; reg awvalid = 0; wire awready;
    reg  [31:0] wdata  = 0; reg [3:0] wstrb = 4'hF; reg wvalid = 0; wire wready;
    wire [1:0]  bresp; wire bvalid; reg bready = 1;
    reg  [31:0] araddr = 0; reg arvalid = 0; wire arready;
    wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready = 1;

    reg  [31:0] s_tdata = 0; reg s_tvalid = 0; wire s_tready;
    wire [31:0] m_tdata; wire m_tvalid, m_tlast; reg m_tready = 0;
    reg  dma_en = 1;

    wire tck, tms, tdi, busy; wire [3:0] chsel; wire [31:0] dbg;
    reg  tdo_in = 1'b0;

    jtag_ctrl dut (
        .clk(clk), .rstn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdi_tdata(s_tdata), .s_axis_tdi_tvalid(s_tvalid), .s_axis_tdi_tready(s_tready),
        .m_axis_tdo_tdata(m_tdata), .m_axis_tdo_tvalid(m_tvalid), .m_axis_tdo_tlast(m_tlast),
        .m_axis_tdo_tready(m_tready), .dma_en(dma_en),
        .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo_in),
        .bcast_sel(1'b0), .busy(busy), .dbg(dbg), .chsel(chsel)
    );

    integer errors = 0;
    task chk(input [8*32-1:0] what, input [31:0] got, input [31:0] exp);
        begin
            if (got !== exp) begin
                $display("FAIL %0s: got 0x%08X expected 0x%08X", what, got, exp);
                errors = errors + 1;
            end else
                $display("ok   %0s = 0x%08X", what, got);
        end
    endtask

    task awr(input [31:0] a, input [31:0] d);
        begin
            @(negedge clk); awaddr = a; awvalid = 1; wdata = d; wvalid = 1;
            @(posedge clk); #1; awvalid = 0; wvalid = 0;
            wait (bvalid === 1'b1); @(posedge clk); #1;
        end
    endtask

    task ard(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk); araddr = a; arvalid = 1;
            @(posedge clk); #1; arvalid = 0;
            wait (rvalid === 1'b1); #1; d = rdata; @(posedge clk); #1;
        end
    endtask

    reg [31:0] v;
    integer i, tv0, tr0, pc0, tv1, tr1, pc1;

    initial begin
        repeat (3) @(posedge clk);
        rstn = 0;
        repeat (3) @(posedge clk);
        rstn = 1;
        repeat (2) @(posedge clk);

        // ---- 1. existing R/W registers must still decode after the widening ----
        awr(32'h00, 32'h1234_5678); ard(32'h00, v); chk("0x00 LEN",    v, 32'h1234_5678);
        awr(32'h04, 32'h0000_0003); ard(32'h04, v); chk("0x04 TMS",    v, 32'h0000_0003);
        awr(32'h08, 32'hDEAD_BEEF); ard(32'h08, v); chk("0x08 TDI",    v, 32'hDEAD_BEEF);
        // 0x14 is write-only DIV; reading it returns the version register {0xA7,...}
        awr(32'h14, 32'h0000_0001); ard(32'h14, v);
        if (v[31:24] !== 8'hA7) begin
            $display("FAIL 0x14 read should be the 0xA7 version register, got 0x%08X", v);
            errors = errors + 1;
        end else $display("ok   0x14 DIV write accepted, read = version 0x%08X", v);
        awr(32'h40, 32'h0000_0ABC); ard(32'h40, v); chk("0x40 BCMASK", v, 32'h0000_0ABC);
        awr(32'h3C, 32'h0000_0005); ard(32'h3C, v); chk("0x3C CHSEL",  v, 32'h0000_0005);

        // ---- 2. counters start at zero and are readable ----
        ard(32'h4C, v); chk("0x4C TVALID_CYC (idle)", v, 0);
        ard(32'h50, v); chk("0x50 TREADY_CYC (idle)", v, 0);
        ard(32'h54, v); chk("0x54 POP_CYC    (idle)", v, 0);

        // ---- 3. push 4 words, let the engine shift them, drain the RX side ----
        m_tready = 1;                       // S2MM ready from the start
        awr(32'h44, 32'd4);                 // arm TLAST on the 4th pop
        tv0 = dut.dbg_tvalid_cyc; tr0 = dut.dbg_tready_cyc; pc0 = dut.dbg_pop_cyc;

        for (i = 0; i < 4; i = i + 1) begin
            @(negedge clk);
            s_tvalid = 1; s_tdata = 32'hAAAA_AAAA + i;
            while (!s_tready) @(negedge clk);
            @(posedge clk);
            @(negedge clk); s_tvalid = 0;
        end

        // 32 bits x 2 clk/bit (DIV=1) per word, plus slack
        repeat (4 * 80 + 200) @(posedge clk);

        tv1 = dut.dbg_tvalid_cyc; tr1 = dut.dbg_tready_cyc; pc1 = dut.dbg_pop_cyc;
        $display("deltas: tvalid=%0d tready=%0d pop=%0d  (stream_cnt=%0d)",
                 tv1-tv0, tr1-tr0, pc1-pc0, dut.stream_cnt);

        if (tv1 == tv0) begin $display("FAIL tvalid never went high"); errors = errors + 1; end
        if (tr1 == tr0) begin $display("FAIL tready never went high"); errors = errors + 1; end
        if (pc1 == pc0) begin $display("FAIL pop never pulsed");       errors = errors + 1; end
        // exactly one pop per completed word
        if ((pc1 - pc0) !== 4) begin
            $display("FAIL pop count %0d != 4 words", pc1 - pc0); errors = errors + 1;
        end
        // a pop needs both sides high, so pop <= min(tvalid, tready)
        if ((pc1 - pc0) > (tv1 - tv0) || (pc1 - pc0) > (tr1 - tr0)) begin
            $display("FAIL pop exceeds tvalid/tready"); errors = errors + 1;
        end
        if (dut.stream_cnt != 4) begin
            $display("FAIL stream_cnt=%0d expected 4", dut.stream_cnt); errors = errors + 1;
        end

        // ---- 4. the register really returns the counter, not the old 0x0C alias ----
        // quiet the tready side first, otherwise it keeps counting while we read
        m_tready = 0;
        repeat (4) @(posedge clk);
        ard(32'h4C, v); chk("0x4C == dbg_tvalid_cyc", v, dut.dbg_tvalid_cyc);
        ard(32'h50, v); chk("0x50 == dbg_tready_cyc", v, dut.dbg_tready_cyc);
        ard(32'h54, v); chk("0x54 == dbg_pop_cyc",    v, dut.dbg_pop_cyc);
        ard(32'h0C, v); chk("0x0C TDO still tdo_q",   v, dut.tdo_q);

        // ---- 5. dmaw_left must reach 0: all four pops consumed the run ----
        chk("0x44 dmaw_left", dut.dmaw_left, 0);

        // ---- 6. the FIFO-clear must not zero the counters ----
        awr(32'h10, 32'h0000_0004);         // ctrl bit2 = FIFO clear
        repeat (4) @(posedge clk);
        ard(32'h4C, v);
        if (v == 0) begin $display("FAIL FIFO clear wiped the counters"); errors = errors + 1; end
        else $display("ok   0x4C survives FIFO clear = 0x%08X", v);

        // ---- 7. back-to-back burst: no word may be lost or overwritten ----
        // This is the mirror image of the pop bug: if tx_wr lagged the handshake,
        // consecutive stream words would both land in the same slot.
        awr(32'h10, 32'h0000_0000);         // release the FIFO clear
        m_tready = 1;
        repeat (4) @(posedge clk);
        ncap0 = ncap;
        burst(200, 32'h5000_0000);

        // 200 words at 32 bits x 2 clk/bit (DIV=1) plus slack
        repeat (200 * 80 + 200) @(posedge clk);

        $display("burst: captured=%0d stream_cnt=%0d tx_diff=%0d drop=%0d",
                 ncap - ncap0, dut.stream_cnt, dut.tx_diff, dut.stream_drop);
        if ((ncap - ncap0) != 200) begin
            $display("FAIL burst: %0d words shifted, expected 200", ncap - ncap0);
            errors = errors + 1;
        end
        for (i = 0; i < 200; i = i + 1)
            if (captured[ncap0 + i] !== (32'h5000_0000 + i)) begin
                $display("FAIL burst word %0d: got 0x%08X expected 0x%08X",
                         i, captured[ncap0 + i], 32'h5000_0000 + i);
                errors = errors + 1;
                if (errors > 12) i = 200;
            end
        if (dut.stream_drop != 0) begin
            $display("FAIL burst dropped %0d words", dut.stream_drop); errors = errors + 1;
        end
        if (dut.tx_diff != 0) begin
            $display("FAIL burst left %0d words in the TX FIFO", dut.tx_diff); errors = errors + 1;
        end
        if (!(errors > 0)) $display("ok   burst of 200 words arrived intact and in order");

        if (errors == 0) $display("\n*** TB PASS ***");
        else             $display("\n*** TB FAIL: %0d error(s) ***", errors);
        $finish;
    end

    // capture the word handed to the shift engine at every tx_pop
    reg [31:0] captured [0:511];
    integer ncap = 0, ncap0 = 0;
    always @(posedge clk) if (dut.tx_pop) begin
        captured[ncap] = dut.tx_mem[dut.tx_rd[6:0]];
        ncap = ncap + 1;
    end

    task burst(input integer n, input [31:0] base);
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(negedge clk);
                s_tvalid = 1; s_tdata = base + k;
                while (!s_tready) @(negedge clk);
                @(posedge clk);
            end
            @(negedge clk); s_tvalid = 0;
        end
    endtask
    initial begin
        #5_000_000;
        $display("*** TB FAIL: timeout (deadlock?) ***");
        $finish;
    end
endmodule
