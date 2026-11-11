`timescale 1ns/1ps
module tb_jtag_ctrl (
    input  wire        clk,
    input  wire        rstn,
    input  wire [31:0] awaddr,
    input  wire        awvalid,
    output wire        awready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        wvalid,
    output wire        wready,
    output wire [1:0]  bresp,
    output wire        bvalid,
    input  wire        bready,
    input  wire [31:0] araddr,
    input  wire        arvalid,
    output wire        arready,
    output wire [31:0] rdata,
    output wire [1:0]  rresp,
    output wire        rvalid,
    input  wire        rready,
    output wire        tck,
    output wire        tms,
    output wire        tdi,
    input  wire        tdo,
    output wire        busy
);

    jtag_ctrl #(.DIV_DEFAULT(2)) dut (
        .clk(clk), .rstn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo), .busy(busy)
    );

    jtag_tap #(.IDCODE(32'h2372_7093)) tap (
        .tck(tck), .tms(tms), .tdi(tdi), .tdo(tdo)
    );

endmodule
