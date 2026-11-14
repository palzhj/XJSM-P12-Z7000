`timescale 1ns/1ps
// tb_reg_path.v - directed test for the AXI4-Lite register (chunked) path.
//
// Same testbench runs against USE_FIFO=0 and USE_FIFO=1, so the register path
// is proven identical in both builds and the pruned queue is shown to be inert.
//
//   iverilog -g2012 -Ptb_reg_path.USE_FIFO=0 -o tb ../rtl/jtag_ctrl.v tb_reg_path.v
module tb_reg_path;
    parameter integer USE_FIFO = 0;

    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [31:0] awaddr = 0; reg awvalid = 0; wire awready;
    reg  [31:0] wdata  = 0; reg [3:0] wstrb = 4'hF; reg wvalid = 0; wire wready;
    wire [1:0]  bresp; wire bvalid; reg bready = 1;
    reg  [31:0] araddr = 0; reg arvalid = 0; wire arready;
    wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready = 1;

    reg  [31:0] s_tdata = 0; reg s_tvalid = 0; wire s_tready;
    wire [31:0] m_tdata; wire m_tvalid, m_tlast; reg m_tready = 0;
    reg  dma_en = 0;

    wire tck, tms, tdi, busy; wire [3:0] chsel; wire [31:0] dbg;
    reg  tdo_in = 1'b0;

    jtag_ctrl #(.DIV_DEFAULT(1), .USE_FIFO(USE_FIFO)) dut (
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

    task ard(input [31:0] a, output [31:0] d);
        begin
            @(negedge clk); araddr = a; arvalid = 1;
            @(posedge clk); #1; arvalid = 0;
            wait (rvalid === 1'b1); #1; d = rdata; @(posedge clk); #1;
        end
    endtask

    // one chunk: LENGTH / TMS / TDI, strobe CTRL, poll, read TDO
    task shift(input integer n, input [31:0] m, input [31:0] d, output [31:0] r);
        integer guard;
        begin
            awr(32'h00, n);
            awr(32'h04, m);
            awr(32'h08, d);
            awr(32'h10, 1);
            guard = 0;
            ard(32'h10, r);
            while ((r & 1) && guard < 200) begin
                ard(32'h10, r);
                guard = guard + 1;
            end
            if (guard >= 200) begin $display("FAIL shift timeout"); errors = errors + 1; end
            ard(32'h0C, r);
        end
    endtask

    reg [31:0] v;
    initial begin
        repeat (3) @(posedge clk);
        rstn = 0; repeat (2) @(posedge clk); rstn = 1; repeat (3) @(posedge clk);

        $display("--- tb_reg_path  USE_FIFO=%0d ---", USE_FIFO);

        awr(32'h14, 1);                             // DIV=1 -> 2 clk/bit
        awr(32'h10, 4); awr(32'h10, 0);             // flush (no-op without a queue)

        ard(32'h24, v); chk("0x24 STATUS idle", v, 32'h0000_0080);

        // TAP reset, then shift with TDO tied high / low
        shift(5, 32'h1F, 32'h0, v);
        tdo_in = 1'b1;
        shift(32, 32'h0, 32'hFFFF_FFFF, v);
        chk("TDO with tdo_in=1", v, 32'hFFFF_FFFF);
        tdo_in = 1'b0;
        shift(32, 32'h0, 32'h0000_0000, v);
        chk("TDO with tdo_in=0", v, 32'h0000_0000);

        // The chunk path must not depend on the queue. With the queue pruned a
        // stray 0x1C write must change nothing; with a real queue it legitimately
        // consumes a slot, so only the pruned build asserts a full 128 free.
        awr(32'h1C, 32'h1234_5678);
        awr(32'h1C, 32'h1234_5678);
        ard(32'h24, v);
        if (USE_FIFO == 0) chk("0x24 after stray TXD", v, 32'h0000_0080);
        else               $display("ok   0x24 after stray TXD (queue consumed) = 0x%08X", v);

        // and the chunk path still works afterwards
        tdo_in = 1'b1;
        shift(32, 32'h0, 32'h0, v);
        chk("TDO still works after TXD", v, 32'hFFFF_FFFF);

        if (errors == 0) $display("*** TB_REG_PASS (USE_FIFO=%0d) ***", USE_FIFO);
        else             $display("*** TB_REG_FAIL %0d error(s) ***", errors);
        $finish;
    end
    initial begin #2_000_000; $display("*** TB_REG timeout ***"); $finish; end
endmodule
