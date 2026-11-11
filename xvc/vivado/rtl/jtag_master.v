// jtag_master.v - AXI4-Lite -> JTAG hardware TAP engine (one shift of <=32 bits per operation)
//
// Registers:
//   0x00 LEN     number of bits to shift, 1..32
//   0x04 TMS     32 bit, bit0 shifted out first
//   0x08 TDI     32 bit, bit0 shifted out first
//   0x0C TDO     readback (bit0 = first sampled bit)
//   0x10 CTRL    write 1 to bit0 to start one shift (increments the sequence number; the engine detects it and runs)
//   0x14 STATUS  bit0 busy
//   0x18 DIV     TCK half-period divider (number of clk cycles), reset value 8
//
// Each register is driven by exactly one always block to avoid multiple drivers.
module jtag_master #(
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
    output wire        busy_o
);

    // ---- software-writable registers (driven only by the AXI write channel) ----
    reg [31:0] reg_len, reg_tms, reg_tdi, reg_div;
    reg [7:0]  start_seq;
    reg        reg_free;

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
            reg_len <= 32'd8; reg_tms <= 32'd0; reg_tdi <= 32'd0;
            reg_div <= DIV_DEFAULT[31:0];
            start_seq <= 8'd0;
            reg_free <= 1'b0;
        end else begin
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;

            if (s_axi_awvalid && s_axi_awready) begin
                waddr <= s_axi_awaddr; aw_done <= 1'b1;
            end
            if (s_axi_wvalid && s_axi_wready) begin
                wdata <= s_axi_wdata; w_done <= 1'b1;
            end

            if (aw_done && w_done) begin
                case (waddr[5:2])
                    4'd0: reg_len <= wdata;
                    4'd1: reg_tms <= wdata;
                    4'd2: reg_tdi <= wdata;
                    4'd4: begin
                              if (wdata[0]) start_seq <= start_seq + 8'd1;
                              reg_free <= wdata[1];   // bit1 = free-running TCK (test)
                          end
                    4'd6: reg_div <= wdata;
                    default: ;
                endcase
                aw_done <= 1'b0; w_done <= 1'b0; s_axi_bvalid <= 1'b1;
            end
        end
    end

    // ---- AXI read channel ----
    always @(posedge clk) begin
        if (!rstn) begin
            s_axi_rvalid <= 1'b0; s_axi_rdata <= 32'd0; s_axi_rresp <= 2'b00;
        end else begin
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 1'b0;

            if (s_axi_arvalid && s_axi_arready) begin
                case (s_axi_araddr[5:2])
                    4'd0: s_axi_rdata <= reg_len;
                    4'd1: s_axi_rdata <= reg_tms;
                    4'd2: s_axi_rdata <= reg_tdi;
                    4'd3: s_axi_rdata <= reg_tdo;
                    4'd5: s_axi_rdata <= {31'd0, busy};
                    4'd6: s_axi_rdata <= reg_div;
                    default: s_axi_rdata <= 32'h00000000;
                endcase
                s_axi_rvalid <= 1'b1;
            end
        end
    end
    assign s_axi_arready = !s_axi_rvalid;

    // ---- JTAG shift engine (drives only its own registers) ----
    localparam IDLE = 2'd0, LOAD = 2'd1, HIGH = 2'd2, LOW = 2'd3;

    reg [1:0]  state;
    reg [31:0] sh_tms, sh_tdi, sh_tdo, reg_tdo;
    reg [5:0]  bits;
    reg [15:0] divcnt;
    reg        busy;
    reg [7:0]  seen_seq;

    wire [15:0] div = (reg_div[15:0] == 16'd0) ? 16'd8 : reg_div[15:0];
    assign busy_o = busy;

    always @(posedge clk) begin
        if (!rstn) begin
            state <= IDLE; tck <= 1'b0; tms <= 1'b0; tdi <= 1'b0;
            reg_tdo <= 32'd0; busy <= 1'b0; seen_seq <= 8'd0;
            sh_tms <= 32'd0; sh_tdi <= 32'd0; sh_tdo <= 32'd0;
            bits <= 6'd0; divcnt <= 16'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (reg_free) begin
                        /* test mode: TCK toggles continuously so the ILA is guaranteed to capture it */
                        if (divcnt == div - 16'd1) begin
                            divcnt <= 16'd0;
                            tck    <= ~tck;
                        end else
                            divcnt <= divcnt + 16'd1;
                    end else begin
                    tck <= 1'b0;
                    if (start_seq != seen_seq) begin
                        seen_seq <= start_seq;
                        busy     <= 1'b1;
                        sh_tms   <= reg_tms;
                        sh_tdi   <= reg_tdi;
                        sh_tdo   <= 32'd0;
                        bits     <= (reg_len == 0) ? 6'd1 : reg_len[5:0];
                        divcnt   <= 16'd0;
                        state    <= LOAD;
                    end
                    end
                end

                LOAD: begin
                    tms <= sh_tms[0];
                    tdi <= sh_tdi[0];
                    tck <= 1'b0;
                    if (divcnt == div - 16'd1) begin
                        divcnt <= 16'd0;
                        state  <= HIGH;
                    end else
                        divcnt <= divcnt + 16'd1;
                end

                HIGH: begin
                    tck <= 1'b1;
                    if (divcnt == div - 16'd1) begin
                        divcnt <= 16'd0;
                        sh_tdo <= {tdo, sh_tdo[31:1]};
                        if (bits == 6'd1)
                            reg_tdo <= {tdo, sh_tdo[31:1]};
                        state <= LOW;
                    end else
                        divcnt <= divcnt + 16'd1;
                end

                LOW: begin
                    tck <= 1'b0;
                    if (divcnt == div - 16'd1) begin
                        divcnt <= 16'd0;
                        busy   <= 1'b0;
                        if (bits == 6'd1)
                            state <= IDLE;
                        else begin
                            bits   <= bits - 6'd1;
                            sh_tms <= {1'b0, sh_tms[31:1]};
                            sh_tdi <= {1'b0, sh_tdi[31:1]};
                            state  <= LOAD;
                        end
                    end else
                        divcnt <= divcnt + 16'd1;
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
