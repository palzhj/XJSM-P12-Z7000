// External BSCAN primitive for the Debug Bridge "External_BSCAN_Master" mode
// (C_BSCAN_MUX=3). The bridge's prim_bscan slave expects the JTAG TAP signals
// from a BSCANE2 primitive; its TDO goes back into the primitive.
module bscan_tap (
    output wire tck,
    output wire tms,
    output wire tdi,
    output wire sel,
    output wire capture,
    output wire shift,
    output wire update,
    output wire drck,
    output wire reset,
    output wire runtest,
    input  wire tdo
);

    BSCANE2 #(
        .JTAG_CHAIN(1)
    ) u_bscane2 (
        .TCK     (tck),
        .TMS     (tms),
        .TDI     (tdi),
        .TDO     (tdo),
        .SEL     (sel),
        .CAPTURE (capture),
        .SHIFT   (shift),
        .UPDATE  (update),
        .DRCK    (drck),
        .RESET   (reset),
        .RUNTEST (runtest)
    );

endmodule
