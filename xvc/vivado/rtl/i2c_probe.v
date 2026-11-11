// i2c_probe.v — free-running I2C address prober (works with ILA, no AXI needed)
//
// Sequence: START -> 8-bit address (0x78/0x7A) -> release SDA to read ACK -> STOP -> wait
// Each phase lasts DIV clocks; SCL frequency = 100MHz / (4*DIV)
//   DIV=8000 -> ~3.1 kHz (several bits fit in one ILA capture window)
//
// Open-drain: scl_low/sda_low = 1 means release (high-Z), 0 means drive low
`timescale 1ns/1ps

module i2c_probe #(
    parameter integer DIV = 8000
) (
    input  wire clk,
    input  wire rstn,
    output reg  scl_low,
    output reg  sda_low,
    input  wire scl_in,
    input  wire sda_in,
    output reg  ack_pulse,
    output reg  ack_val,
    output reg  [3:0] st_dbg,
    output reg  [7:0] addr_dbg,
    output reg  [7:0] ack_cnt,      /* number of responding devices */
    output reg  [7:0] first_ack,    /* first responding address (8-bit write address) */
    output reg  [7:0] scan_addr     /* current scan address (8-bit write address) */
);

    localparam [3:0]
        P_IDLE   = 4'd0,
        P_START  = 4'd1,   // SDA low (SCL high)
        P_SCLLOW = 4'd2,
        P_BITLO  = 4'd3,   // present data bit (SCL low)
        P_BITHI  = 4'd4,   // SCL high
        P_ACKLO  = 4'd5,   // release SDA (SCL low)
        P_ACKHI  = 4'd6,   // drive SCL high
        P_ACKS   = 4'd11,  // sample ACK while SCL is high
        P_STOPA  = 4'd7,   // SDA low (SCL low)
        P_STOPB  = 4'd8,   // SCL high
        P_STOPC  = 4'd9,   // SDA high -> STOP
        P_WAIT   = 4'd10;

    reg [15:0] div_cnt;
    reg [3:0]  ph;
    reg [3:0]  bitidx;
    reg [7:0]  shift;
    reg        use_7a;
    reg        ack_seen;
    reg [19:0] wait_cnt;

    wire ph_end = (div_cnt == (DIV - 1));

    always @(posedge clk) begin
        if (!rstn) begin
            div_cnt <= 16'd0; ph <= P_IDLE; bitidx <= 4'd0; shift <= 8'h78;
            use_7a <= 1'b0; wait_cnt <= 20'd0;
            scl_low <= 1'b1; sda_low <= 1'b1;
            ack_pulse <= 1'b0; ack_val <= 1'b1;
            ack_cnt <= 8'd0; first_ack <= 8'hFF; scan_addr <= 8'h00;
            st_dbg <= P_IDLE; addr_dbg <= 8'h78;
        end else begin
            ack_pulse <= 1'b0;
            if (ph_end) begin
                div_cnt <= 16'd0;
                case (ph)
                    P_IDLE: begin
                        // start condition: release both lines, then pull SDA low
                        scl_low <= 1'b1; sda_low <= 1'b1;
                        shift   <= scan_addr;
                        addr_dbg<= scan_addr;
                        bitidx  <= 4'd0;
                        ph      <= P_START;
                        st_dbg  <= P_START;
                    end
                    P_START: begin
                        sda_low <= 1'b0;          // SDA low (SCL still high) => START
                        ph <= P_SCLLOW;
                        st_dbg <= P_SCLLOW;
                    end
                    P_SCLLOW: begin
                        scl_low <= 1'b0;          // SCL low
                        ph <= P_BITLO;
                        st_dbg <= P_BITLO;
                    end
                    P_BITLO: begin
                        if (bitidx == 4'd8) begin
                            sda_low <= 1'b1;      // all 8 bits sent, release SDA
                            ph <= P_ACKHI;        // go straight to the ACK clock
                            st_dbg <= P_ACKHI;
                        end else begin
                            sda_low <= ~shift[7]; // present the current bit
                            shift   <= {shift[6:0], 1'b0};
                            bitidx  <= bitidx + 4'd1;
                            scl_low <= 1'b1;      // SCL high
                            ph <= P_BITHI;
                            st_dbg <= P_BITHI;
                        end
                    end
                    P_BITHI: begin
                        scl_low <= 1'b0;          // SCL low, prepare next bit
                        ph <= P_BITLO;
                        st_dbg <= P_BITLO;
                    end
                    P_ACKHI: begin
                        scl_low <= 1'b1;          // raise SCL first (no sampling this cycle)
                        ph <= P_ACKS;
                        st_dbg <= P_ACKS;
                    end
                    P_ACKS: begin
                        ack_val   <= sda_in;      // SCL is stably high, sample ACK
                        ack_pulse <= 1'b1;
                        if (sda_in == 1'b0) begin          // ACK received
                            ack_cnt <= ack_cnt + 8'd1;
                            if (first_ack == 8'hFF) first_ack <= scan_addr;
                        end
                        ph <= P_ACKLO;
                        st_dbg <= P_ACKLO;
                    end
                    P_ACKLO: begin
                        scl_low <= 1'b0;          // SCL low
                        ph <= P_STOPA;
                        st_dbg <= P_STOPA;
                    end
                    P_STOPA: begin
                        sda_low <= 1'b0;          // SDA low (SCL low)
                        ph <= P_STOPB;
                        st_dbg <= P_STOPB;
                    end
                    P_STOPB: begin
                        scl_low <= 1'b1;          // SCL high
                        ph <= P_STOPC;
                        st_dbg <= P_STOPC;
                    end
                    P_STOPC: begin
                        sda_low <= 1'b1;          // SDA high => STOP
                        /* scan: address +2 (8-bit write address), wrap to 0 after 0xFE */
                        if (scan_addr >= 8'hFE) scan_addr <= 8'h00;
                        else                    scan_addr <= scan_addr + 8'd2;
                        wait_cnt<= 20'd0;
                        ph <= P_WAIT;
                        st_dbg <= P_WAIT;
                    end
                    P_WAIT: begin
                        if (wait_cnt >= 20'd20000) begin
                            wait_cnt <= 20'd0;
                            ph <= P_IDLE;
                            st_dbg <= P_IDLE;
                        end else begin
                            wait_cnt <= wait_cnt + 20'd1;
                        end
                    end
                    default: begin ph <= P_IDLE; st_dbg <= P_IDLE; end
                endcase
            end else begin
                div_cnt <= div_cnt + 16'd1;
            end
        end
    end
endmodule
