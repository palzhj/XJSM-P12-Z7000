// jtag_repeater.v — 12-channel TCK/TMS/TDI arbitration + TDO selection
//
// Purely combinational, no registers. Upstream are 13 **identical** jtag_ctrl instances:
//   - ch[0..11]: 12 channel engines, each corresponding to one pin group on J20/J21
//   - bc       : the 13th engine, dedicated to broadcast
//
// Control registers come from jtag_bcast_regs:
//   bcast_en   1 = broadcast mode
//   bcmask_eff [11:0] channels participating in broadcast (0 already expanded upstream to all-selected)
//   chsel      [3:0]  which TDO lane to read back during broadcast
//
// Per channel:
//   follow = bcast_en & bcmask_eff[i]
//   pin_tck[i] = follow ? bc_tck : ch_tck[i]    etc.
//   bc_tdo     = ch_tdo[chsel] (1 of 12)

module jtag_repeater (
    /* control */
    input  wire        bcast_en,
    input  wire [11:0] bcmask_eff,
    input  wire [3:0]  chsel,

    /* broadcast engine (the 13th jtag_ctrl) */
    input  wire        bc_tck,
    input  wire        bc_tms,
    input  wire        bc_tdi,
    output wire        bc_tdo,

    /* 12 channel engines (vectors indexed by bit, bit0 = ch0) */
    input  wire [11:0] ch_tck,
    input  wire [11:0] ch_tms,
    input  wire [11:0] ch_tdi,
    input  wire [11:0] ch_tdo,

    /* whether each channel follows broadcast (feeds that engine's bcast_sel) */
    output wire [11:0] follow,

    /* 12 pin groups to J20/J21 */
    output wire [11:0] pin_tck,
    output wire [11:0] pin_tms,
    output wire [11:0] pin_tdi
);

    genvar i;
    generate
        for (i = 0; i < 12; i = i + 1) begin : g_ch
            assign follow[i]  = bcast_en & bcmask_eff[i];
            assign pin_tck[i] = follow[i] ? bc_tck : ch_tck[i];
            assign pin_tms[i] = follow[i] ? bc_tms : ch_tms[i];
            assign pin_tdi[i] = follow[i] ? bc_tdi : ch_tdi[i];
        end
    endgenerate

    /* TDO input of the broadcast engine: pick one of the 12 lanes */
    assign bc_tdo = (chsel < 4'd12) ? ch_tdo[chsel] : 1'b0;

endmodule
