// jtag_bcast_mux.v — pin arbitration between the broadcast engine and the 12 independent engines (per channel)
//
// Hardware premise: on J20/J21 the TCK/TMS/TDI of the 12 interfaces are the **same net group** on the
// board; only TDO is independent per interface. Therefore:
//   - when a broadcast client is connected, the selected channels (bc_mask bit = 1) switch to the
//     broadcast engine, which drives TCK/TMS/TDI for all of them;
//   - channels not selected are still driven by their own engines;
//   - which TDO lane the broadcast engine reads back is determined by CHSEL (0x3C).
//
// Conflict protection: each channel's TCK/TMS/TDI is a 1-of-3 mux, so there is exactly one driver at any time.

module jtag_bcast_mux (
    input  wire        bcast_en,     /* 1 = broadcast client online (from bcast engine CTRL bit4) */
    input  wire [11:0] bc_mask,      /* which channels follow broadcast (bcast engine BCMASK) */
    input  wire        bc_tck,
    input  wire        bc_tms,
    input  wire        bc_tdi,
    input  wire [3:0]  tdo_sel,      /* which TDO lane to read during broadcast (bcast engine CHSEL) */

    /* 12 channel engines */
    input  wire [11:0] ch_tck,
    input  wire [11:0] ch_tms,
    input  wire [11:0] ch_tdi,
    input  wire [11:0] ch_tdo,       /* TDO of the 12 interfaces (from the pins) */

    /* to J20/J21 */
    output wire [11:0] pin_tck,
    output wire [11:0] pin_tms,
    output wire [11:0] pin_tdi,

    /* TDO as seen by the broadcast engine (1 of 12) */
    output wire        bc_tdo
);

    /* when the mask is 0 treat it as "all selected" (the BCMASK register reads back 0 in some bitstreams,
       in which case broadcast should apply to all 12 interfaces) */
    wire [11:0] mask_eff = (bc_mask == 12'd0) ? 12'hFFF : bc_mask;

    genvar i;
    generate
        for (i = 0; i < 12; i = i + 1) begin : g_pin
            wire follow = bcast_en & mask_eff[i];  /* whether this channel follows broadcast */
            assign pin_tck[i] = follow ? bc_tck : ch_tck[i];
            assign pin_tms[i] = follow ? bc_tms : ch_tms[i];
            assign pin_tdi[i] = follow ? bc_tdi : ch_tdi[i];
        end
    endgenerate

    assign bc_tdo = (tdo_sel < 4'd12) ? ch_tdo[tdo_sel] : 1'b0;

endmodule
