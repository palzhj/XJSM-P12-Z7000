`timescale 1ns/1ps
// tb_xapp1251.v - directed test for the XAPP1251 register-only JTAG controller.
//
//   iverilog -g2012 -o tb ../src/jtag_xapp1251.v tb_xapp1251.v && ./tb
module tb_xapp1251;
    reg clk = 0, rstn = 0;
    always #5 clk = ~clk;

    reg  [31:0] awaddr = 0; reg awvalid = 0; wire awready;
    reg  [31:0] wdata  = 0; reg [3:0] wstrb = 4'hF; reg wvalid = 0; wire wready;
    wire [1:0]  bresp; wire bvalid; reg bready = 1;
    reg  [31:0] araddr = 0; reg arvalid = 0; wire arready;
    wire [31:0] rdata; wire [1:0] rresp; wire rvalid; reg rready = 1;

    wire tck, tms, tdi, busy;
    reg  tdo_in = 1'b0;

    jtag_xapp1251 #(.TCK_DIV(5)) dut (
        .clk(clk), .rstn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo_in), .busy(busy)
    );

    integer errors = 0;
    task chk(input [8*44-1:0] what, input [31:0] got, input [31:0] exp);
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

    // XAPP1251 host sequence: vectors, then CTRL.start, poll CTRL until busy clears
    task shift(input integer n, input [31:0] m, input [31:0] d, output [31:0] r);
        integer guard;
        begin
            awr(32'h00, n);
            awr(32'h04, m);
            awr(32'h08, d);
            awr(32'h10, 32'h1);
            guard = 0;
            ard(32'h10, r);
            while ((r & 1) && guard < 500) begin
                ard(32'h10, r);
                guard = guard + 1;
            end
            if (guard >= 500) begin $display("FAIL shift timeout"); errors = errors + 1; end
            ard(32'h0C, r);
        end
    endtask

    reg [31:0] v;
    integer t0, t1, nbits;
    initial begin
        repeat (3) @(posedge clk);
        rstn = 0; repeat (2) @(posedge clk); rstn = 1; repeat (3) @(posedge clk);

        $display("--- tb_xapp1251 (TCK_DIV=5) ---");

        // register file
        awr(32'h00, 32'h11); ard(32'h00, v); chk("0x00 LENGTH", v, 32'h11);
        awr(32'h04, 32'h22); ard(32'h04, v); chk("0x04 TMS_VECTOR", v, 32'h22);
        awr(32'h08, 32'h33); ard(32'h08, v); chk("0x08 TDI_VECTOR", v, 32'h33);
        ard(32'h10, v); chk("0x10 CTRL idle", v, 32'h0);

        // TAP reset, then a full 32-bit shift with TDO tied high
        shift(5, 32'h1F, 32'h0, v);
        tdo_in = 1'b1;
        shift(32, 32'h0, 32'hFFFF_FFFF, v);
        chk("TDO with tdo_in=1", v, 32'hFFFF_FFFF);
        tdo_in = 1'b0;
        shift(32, 32'h0, 32'h0000_0000, v);
        chk("TDO with tdo_in=0", v, 32'h0000_0000);

        // CTRL must read busy while a shift is in flight, then clear
        awr(32'h00, 32);
        awr(32'h04, 32'h0);
        awr(32'h08, 32'h0);
        awr(32'h10, 32'h1);
        ard(32'h10, v); chk("CTRL busy during shift", v & 1, 32'h1);
        while (v & 1) ard(32'h10, v);
        chk("CTRL clears when done", v & 1, 32'h0);

        // one bit at 2*TCK_DIV clocks: 32 bits must take 320 clocks (+ slack)
        @(negedge clk); t0 = $time;
        shift(32, 32'h0, 32'h0, v);
        @(negedge clk); t1 = $time;
        nbits = (t1 - t0) / 10;
        $display("    32-bit shift took ~%0d clocks (2*TCK_DIV*32 = 320, plus AXI)", nbits);
        if (nbits < 320) begin $display("FAIL too fast to be real"); errors = errors + 1; end
        else $display("ok   at least 320 clocks -> TCK division is in effect");

        if (errors == 0) $display("*** TB_XAPP1251_PASS ***");
        else             $display("*** TB_XAPP1251_FAIL %0d ***", errors);
        $finish;
    end
    initial begin #3_000_000; $display("*** TB_XAPP1251 timeout ***"); $finish; end
endmodule
