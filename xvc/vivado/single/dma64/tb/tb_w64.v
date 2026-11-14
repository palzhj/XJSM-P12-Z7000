`timescale 1ns/1ps
// tb_w64.v - the wide stream must drive TMS from the queue, not force zeros.
//
// Pushes {TMS, TDI} words and captures the real tms/tdi pins on every TCK rising
// edge, then compares the captured bit stream against what was pushed. The old
// 32-bit stream could never pass this: it held TMS at 0 for every word.
module tb_w64;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [31:0] awaddr = 0; reg awvalid = 0; wire awready;
    reg  [31:0] wdata  = 0; reg [3:0] wstrb = 4'hF; reg wvalid = 0; wire wready;
    wire [1:0]  bresp; wire bvalid; reg bready = 1;
    reg  [31:0] araddr = 0; reg arvalid = 0; wire arready;
    wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready = 1;

    reg  [63:0] s_tdata = 0; reg s_tvalid = 0; wire s_tready;
    wire [31:0] m_tdata; wire m_tvalid, m_tlast; reg m_tready = 1;
    reg  dma_en = 1;

    wire tck, tms, tdi, busy; wire [3:0] chsel; wire [31:0] dbg;
    reg  tdo_in = 1'b0;

    jtag_w64 #(.DIV_DEFAULT(5), .USE_FIFO(1)) dut (
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

    // capture the pins on every TCK rising edge
    reg [31:0] cap_tms = 0, cap_tdi = 0;
    integer ncap = 0;
    always @(posedge tck) begin
        cap_tms = {cap_tms[30:0], tms};
        cap_tdi = {cap_tdi[30:0], tdi};
        ncap = ncap + 1;
    end

    function [31:0] rev;
        input [31:0] v;
        integer k;
        begin
            for (k = 0; k < 32; k = k + 1) rev[k] = v[31 - k];
        end
    endfunction

    integer errors = 0;
    task chk(input [8*40-1:0] what, input [31:0] got, input [31:0] exp);
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

    task push(input [63:0] w);
        begin
            @(negedge clk); s_tdata = w; s_tvalid = 1;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
            @(negedge clk); s_tvalid = 0;
        end
    endtask

    // one 32-bit word at DIV=5 is 32*2*5 = 320 clocks; give it margin. Waiting on
    // `busy` alone is wrong: it is still 0 on the cycle the word is pushed.
    task settle;
        begin
            repeat (600) @(posedge clk);
        end
    endtask

    // TMS vectors that must appear on the pin, bit 0 first
    reg [63:0] w;
    reg [31:0] tms_vec, tdi_vec;
    integer i;
    initial begin
        repeat (3) @(posedge clk);
        rstn = 0; repeat (2) @(posedge clk); rstn = 1; repeat (3) @(posedge clk);

        $display("--- tb_w64: does TMS come from the stream? ---");

        // word 1: TMS = 0xA5A5A5A5, TDI = 0x12345678
        tms_vec = 32'hA5A5_A5A5; tdi_vec = 32'h1234_5678;
        w = {tms_vec, tdi_vec};
        ncap = 0;
        push(w);
        $display("dbg: tready=%b tx_wr=%0d tx_rd=%0d tx_full=%b dma_en=%b state=%0d tvalid=%b",
                 s_tready, dut.tx_wr, dut.tx_rd, dut.tx_full, dut.dma_en, dut.state, s_tvalid);
        settle();
        // the engine drops the last sampled bit, so compare the captured window
        chk("TMS from stream (0xA5A5A5A5, bit-reversed)", cap_tms, rev(tms_vec));
        chk("TDI from stream (0x12345678, bit-reversed)", cap_tdi, rev(tdi_vec));
        chk("bit count", ncap, 32);

        // word 2: TMS = 0xFFFFFFFF would leave the TAP in reset; use a run of ones
        tms_vec = 32'h0000_001F; tdi_vec = 32'hDEAD_BEEF;
        w = {tms_vec, tdi_vec};
        ncap = 0;
        push(w);
        $display("dbg: tready=%b tx_wr=%0d tx_rd=%0d tx_full=%b dma_en=%b state=%0d tvalid=%b",
                 s_tready, dut.tx_wr, dut.tx_rd, dut.tx_full, dut.dma_en, dut.state, s_tvalid);
        settle();
        chk("TMS from stream (0x0000001F, bit-reversed)", cap_tms, rev(tms_vec));
        chk("TDI from stream (0xDEADBEEF, bit-reversed)", cap_tdi, rev(tdi_vec));

        // and a word pushed through the register path must still be TMS=0
        ncap = 0;
        awr(32'h00, 32); awr(32'h04, 0); awr(32'h08, 32'hC0FF_EE00); awr(32'h10, 1);
        settle();
        chk("register-path TMS stays 0", cap_tms, 32'h0);
        chk("register-path TDI (bit-reversed)", cap_tdi, rev(32'hC0FF_EE00));

        if (errors == 0) $display("*** TB_W64_PASS: TMS travels in the stream ***");
        else             $display("*** TB_W64_FAIL %0d ***", errors);
        $finish;
    end
    initial begin #5_000_000; $display("*** TB_W64 timeout ***"); $finish; end
endmodule
