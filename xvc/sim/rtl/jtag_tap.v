// Minimal JTAG TAP used to validate the XVC shift convention (LSB first,
// 32-bit chunks) independently of the real Debug Bridge IP.
//
// IR is 4 bit: 4'h2 = IDCODE (reset value), 4'hF = BYPASS.
module jtag_tap #(
    parameter [31:0] IDCODE = 32'h2372_7093
) (
    input  wire tck,
    input  wire tms,
    input  wire tdi,
    output reg  tdo,
    output reg  [3:0] ir,
    output wire in_shift_dr,
    output wire in_shift_ir
);

    // state encoding
    localparam TLR=0, RTI=1, SEL_DR=2, CAP_DR=3, SHIFT_DR=4, EXIT1_DR=5,
               PAUSE_DR=6, EXIT2_DR=7, UPD_DR=8, SEL_IR=9, CAP_IR=10,
               SHIFT_IR=11, EXIT1_IR=12, PAUSE_IR=13, EXIT2_IR=14, UPD_IR=15;

    reg [3:0] state;
    reg [31:0] dr;
    reg        dr1;          // 1-bit BYPASS register

    assign in_shift_dr = (state == SHIFT_DR);
    assign in_shift_ir = (state == SHIFT_IR);

    // TDO changes on the falling edge (as in a real TAP), so the host samples
    // the pre-shift LSb on the next rising edge.
    always @(negedge tck) begin
        case (state)
            SHIFT_DR: tdo <= (ir == 4'hF) ? dr1 : dr[0];
            SHIFT_IR: tdo <= ir[0];
            default:  tdo <= 1'b0;
        endcase
    end

    always @(posedge tck) begin
        case (state)
            TLR:      state <= tms ? TLR : RTI;
            RTI:      state <= tms ? SEL_DR : RTI;
            SEL_DR:   state <= tms ? SEL_IR : CAP_DR;
            CAP_DR:   state <= tms ? EXIT1_DR : SHIFT_DR;
            SHIFT_DR: begin
                          if (ir == 4'hF) dr1 <= tdi;
                          else            dr  <= {tdi, dr[31:1]};
                          state <= tms ? EXIT1_DR : SHIFT_DR;
                      end
            EXIT1_DR: state <= tms ? UPD_DR : PAUSE_DR;
            PAUSE_DR: state <= tms ? EXIT2_DR : PAUSE_DR;
            EXIT2_DR: state <= tms ? UPD_DR : SHIFT_DR;
            UPD_DR:   state <= tms ? SEL_DR : RTI;
            SEL_IR:   state <= tms ? TLR : CAP_IR;
            CAP_IR:   state <= tms ? EXIT1_IR : SHIFT_IR;
            SHIFT_IR: begin
                          ir  <= {tdi, ir[3:1]};
                          state <= tms ? EXIT1_IR : SHIFT_IR;
                      end
            EXIT1_IR: state <= tms ? UPD_IR : PAUSE_IR;
            PAUSE_IR: state <= tms ? EXIT2_IR : PAUSE_IR;
            EXIT2_IR: state <= tms ? UPD_IR : SHIFT_IR;
            UPD_IR:   state <= tms ? SEL_DR : RTI;
            default:  state <= TLR;
        endcase

        // capture on entry to CAP_DR
        if (state == CAP_DR && !tms) begin
            if (ir == 4'h2)      dr  <= IDCODE;
            else if (ir == 4'hF) dr1 <= 1'b0;
            else                 dr  <= 32'b0;
        end
    end

    initial begin
        tdo    = 1'b0;
        state  = TLR;
        ir     = 4'h2;
        dr     = 32'b0;
        dr1    = 1'b0;
    end

endmodule
