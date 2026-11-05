// SPDX-License-Identifier: MIT
//
// omac_gt_usp_gth_quad - four UltraScale+ GTH channels of one quad as four
// INDEPENDENT 10GBASE-R lanes, one omac_10g per lane (for example the four
// ports of a quad SFP28 card): the gtwizard_ultrascale IP made by gen_gt.tcl
// omac_gen_gth_quad (module omac_gth_quad, the omac_gen_gth_x4 settings plus
// per-channel RXPMARESET / RXRESETDONE / RXCDRLOCK / QPLL0LOCK ports).
// Differences to omac_gt_usp_gth_x4 (one omac_40g on four lanes):
//   * per-lane RX reset: gt_rx_reset_req[l] (the omac watchdog of lane l, or
//     software) pulses that channel's RXPMARESET only (a sequential PMA + PCS
//     reset of that channel's receiver), so a lane without signal never
//     disturbs the other three; gt_rx_ready[l] is per lane (0 from the request
//     until the channel's RXRESETDONE returns). The gtwizard's own RX datapath
//     reset (all channels) is not used after power-up.
//   * per-lane loopback, polarity and transmit driver settings.
//   * TX: one user clock for all lanes (the master channel's TXOUTCLK, as in
//     _x4): tx_usrclk2 = the clk of all four omac_10g (and a natural time base
//     for a design's time-of-day counter).
//   * RX: every channel has its own user clock from its own RXOUTCLK (two
//     BUFG_GT per lane), rx_usrclk2[l] = omac gt_rx_clk of lane l (the
//     recovered clock of that port).
//   * lanes: port lane l is the gtwizard channel CH_OF_LANE[2l +: 2] (ascending
//     site order inside the IP: X0Y12 = 0 ... X0Y15 = 3); the default is the
//     _x4 example (X0Y14 X0Y13 X0Y15 X0Y12).
//   * status: qpll_lock, per-lane rx_cdr_lock and rx_reset_busy.
//   * refclk_mon: the reference clock / 8 (IBUFDS_GTE4 ODIV2 -> BUFG_GT), running
//     whenever the reference clock does (independent of every GT reset), for a
//     frequency monitor in the design (19.53125 MHz at 156.25 MHz).
// Per-lane request handshake (freerun_clk): a rising edge of the synchronised
// gt_rx_reset_req[l] holds RXPMARESET for RST_CYCLES, then waits for
// RXRESETDONE to fall and rise again (each wait bounded: DONE_LOW_CYCLES,
// DONE_HIGH_CYCLES); requests during a reset are ignored.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_gt_usp_gth_quad #(
    parameter bit       BIT_REVERSE      = 1'b1,
    parameter bit [7:0] CH_OF_LANE       = {2'd0, 2'd3, 2'd1, 2'd2},   // lane 3..0 -> channel index
    parameter int       RST_CYCLES       = 32,         // freerun_clk cycles of RXPMARESET
    parameter int       DONE_LOW_CYCLES  = 4096,       // wait for RXRESETDONE to fall
    parameter int       DONE_HIGH_CYCLES = 1048576     // wait for RXRESETDONE to rise (10 ms at 100 MHz)
) (
    input  wire logic         refclk_p,
    input  wire logic         refclk_n,
    input  wire logic         freerun_clk,
    input  wire logic         reset_all,

    // serial pins, by lane (the channel LOCs come with the IP)
    input  wire logic [3:0]   gth_rxp,
    input  wire logic [3:0]   gth_rxn,
    output wire logic [3:0]   gth_txp,
    output wire logic [3:0]   gth_txn,

    // omac GT side, by lane
    output wire logic         tx_usrclk2,      // = clk of every omac_10g
    output wire logic         gt_tx_ready,
    input  wire logic [7:0]   gt_tx_hdr,
    input  wire logic [255:0] gt_tx_data,
    output wire logic [3:0]   rx_usrclk2,      // = omac gt_rx_clk, per lane
    output logic      [3:0]   gt_rx_ready,
    output wire logic [3:0]   gt_rx_valid,
    output wire logic [7:0]   gt_rx_hdr,
    output wire logic [255:0] gt_rx_data,
    input  wire logic [3:0]   gt_rx_slip,
    input  wire logic [3:0]   gt_rx_reset_req,  // per lane, any clock (a pulse >= 2 freerun_clk cycles or a level)
    input  wire logic [11:0]  gt_loopback,      // lane l at [3l +: 3]

    // transceiver settings, by lane (static)
    input  wire logic [3:0]   tx_polarity,
    input  wire logic [3:0]   rx_polarity,
    input  wire logic [19:0]  tx_diffctrl,      // lane l at [5l +: 5], e.g. 5'b11000
    input  wire logic [19:0]  tx_postcursor,
    input  wire logic [19:0]  tx_precursor,
    input  wire logic [3:0]   rx_lpmen,         // 0: DFE (cables), 1: LPM

    output wire logic [3:0]   gt_powergood,
    output wire logic         qpll_lock,
    output wire logic [3:0]   rx_cdr_lock,
    output logic      [3:0]   rx_reset_busy,
    output wire logic         refclk_mon
);

wire refclk, refclk_odiv2;
IBUFDS_GTE4 #(
    .REFCLK_EN_TX_PATH (1'b0),
    .REFCLK_HROW_CK_SEL(2'b00),
    .REFCLK_ICNTL_RX   (2'b00)
) u_refclk_buf (.I(refclk_p), .IB(refclk_n), .CEB(1'b0), .O(refclk), .ODIV2(refclk_odiv2));
BUFG_GT u_refclk_mon (.CE(1'b1), .CEMASK(1'b0), .CLR(1'b0), .CLRMASK(1'b0), .DIV(3'd7),
                      .I(refclk_odiv2), .O(refclk_mon));

// ---------------- per-channel vectors of the core (channel index c) ----------------
wire [255:0] txdata_c, rxdata_c;
wire [23:0]  txheader_c, rxheader_c;
wire [7:0]   rxdatavalid_c, rxheadervalid_c;
wire [3:0]   rxslip_c, rxpol_c, txpol_c, rxp_c, rxn_c, txp_c, txn_c, pg_c, lpm_c;
wire [11:0]  lb_c;
wire [19:0]  diff_c, post_c, pre_c;
wire [3:0]   rxoutclk_c, rxusrclk_c, rxusrclk2_c, rx_active_c;
wire [3:0]   txpmaresetdone, rxpmaresetdone, txprgdivresetdone, rxprgdivresetdone;
wire [3:0]   rxresetdone_c, rxcdrlock_c;
wire  [3:0]  pmareset_c;
wire [3:0]   qlock;
wire         tx_done, rx_done, tx_active;
logic        rx_done_s;            // rx_done (master RX user clock domain) in freerun_clk
wire  [3:0]  lane_busy;            // freerun_clk, by lane
wire  [3:0]  lane_done_s;          // RXRESETDONE of the lane's channel, synchronised
wire  [3:0]  lane_act_s;           // the lane's RX user clock active, synchronised

for (genvar l = 0; l < 4; l++) begin : g_lane
    localparam int C = CH_OF_LANE[2*l +: 2];
    for (genvar i = 0; i < 64; i++) begin : g_bits
        assign txdata_c[64*C + i]  = BIT_REVERSE ? gt_tx_data[64*l + 63 - i] : gt_tx_data[64*l + i];
        assign gt_rx_data[64*l + i] = BIT_REVERSE ? rxdata_c[64*C + 63 - i]  : rxdata_c[64*C + i];
    end
    assign txheader_c[6*C +: 6] = {4'd0, BIT_REVERSE ? {gt_tx_hdr[2*l], gt_tx_hdr[2*l+1]} : gt_tx_hdr[2*l +: 2]};
    assign gt_rx_hdr[2*l +: 2]  = BIT_REVERSE ? {rxheader_c[6*C], rxheader_c[6*C+1]} : rxheader_c[6*C +: 2];
    assign gt_rx_valid[l]       = rxdatavalid_c[2*C] && rxheadervalid_c[2*C];
    assign rxslip_c[C]          = gt_rx_slip[l];
    assign rxpol_c[C]           = rx_polarity[l];
    assign txpol_c[C]           = tx_polarity[l];
    assign lpm_c[C]             = rx_lpmen[l];
    assign lb_c[3*C +: 3]       = gt_loopback[3*l +: 3];
    assign diff_c[5*C +: 5]     = tx_diffctrl[5*l +: 5];
    assign post_c[5*C +: 5]     = tx_postcursor[5*l +: 5];
    assign pre_c[5*C +: 5]      = tx_precursor[5*l +: 5];
    assign rxp_c[C]             = gth_rxp[l];
    assign rxn_c[C]             = gth_rxn[l];
    assign gth_txp[l]           = txp_c[C];
    assign gth_txn[l]           = txn_c[C];
    assign gt_powergood[l]      = pg_c[C];
    assign rx_usrclk2[l]        = rxusrclk2_c[C];
    assign rx_cdr_lock[l]       = rxcdrlock_c[C];

    // ---- per-lane RX reset (freerun_clk) ----
    logic req_s, done_s, act_s;
    omac_sync_bit #(.WIDTH(3)) u_sync (.clk(freerun_clk),
        .din({gt_rx_reset_req[l], rxresetdone_c[C], rx_active_c[C]}), .dout({req_s, done_s, act_s}));
    assign lane_done_s[l] = done_s;
    assign lane_act_s[l]  = act_s;
    typedef enum logic [1:0] { L_IDLE, L_PMA, L_WLOW, L_WHIGH } lst_t;
    lst_t        lst = L_IDLE;
    logic        req_d = 1'b0;
    logic [20:0] tmr = '0;
    always_ff @(posedge freerun_clk) begin
        req_d <= req_s;
        case (lst)
            L_IDLE: if (req_s && !req_d && rx_done_s) begin
                lst <= L_PMA;
                tmr <= 21'(RST_CYCLES);
            end
            L_PMA: if (tmr == '0) begin
                lst <= L_WLOW;
                tmr <= 21'(DONE_LOW_CYCLES);
            end else tmr <= tmr - 1'b1;
            L_WLOW: if (!done_s || tmr == '0) begin
                lst <= L_WHIGH;
                tmr <= 21'(DONE_HIGH_CYCLES);
            end else tmr <= tmr - 1'b1;
            default: if (done_s || tmr == '0) lst <= L_IDLE;
                     else tmr <= tmr - 1'b1;
        endcase
        if (reset_all) lst <= L_IDLE;
    end
    assign pmareset_c[C] = (lst == L_PMA);
    assign lane_busy[l]  = (lst != L_IDLE);
end

// ---------------- RX user clocks, one pair per channel ----------------
for (genvar c = 0; c < 4; c++) begin : g_rxclk
    wire rst_uc = !(rxprgdivresetdone[c] && rxpmaresetdone[c]);
    BUFG_GT u_usrclk (.CE(1'b1), .CEMASK(1'b0), .CLR(rst_uc), .CLRMASK(1'b0), .DIV(3'd0),
                      .I(rxoutclk_c[c]), .O(rxusrclk_c[c]));
    BUFG_GT u_usrclk2 (.CE(1'b1), .CEMASK(1'b0), .CLR(rst_uc), .CLRMASK(1'b0), .DIV(3'd1),
                       .I(rxoutclk_c[c]), .O(rxusrclk2_c[c]));
    (* ASYNC_REG = "TRUE" *) logic act_meta = 1'b0, act = 1'b0;
    always_ff @(posedge rxusrclk2_c[c] or posedge rst_uc) begin
        if (rst_uc) begin
            act_meta <= 1'b0;
            act      <= 1'b0;
        end else begin
            act_meta <= 1'b1;
            act      <= act_meta;
        end
    end
    assign rx_active_c[c] = act;
end

assign gt_tx_ready = tx_done && tx_active;
assign qpll_lock   = qlock[0];

// per-lane readiness (freerun_clk): the IP's RX reset done, this lane's user clock
// running, its channel's RX reset done, no per-lane reset in progress
omac_sync_bit u_sync_rxdone (.clk(freerun_clk), .din(rx_done), .dout(rx_done_s));
always_ff @(posedge freerun_clk) begin
    for (int l = 0; l < 4; l++) gt_rx_ready[l] <= rx_done_s && lane_act_s[l] && lane_done_s[l] && !lane_busy[l];
    rx_reset_busy <= lane_busy;
end

omac_gth_quad u_gt (
    .gtwiz_userclk_tx_reset_in          (~(&txprgdivresetdone && &txpmaresetdone)),
    .gtwiz_userclk_tx_srcclk_out        (),
    .gtwiz_userclk_tx_usrclk_out        (),
    .gtwiz_userclk_tx_usrclk2_out       (tx_usrclk2),
    .gtwiz_userclk_tx_active_out        (tx_active),
    .gtwiz_userclk_rx_active_in         (&rx_active_c),
    .gtwiz_reset_clk_freerun_in         (freerun_clk),
    .gtwiz_reset_all_in                 (reset_all),
    .gtwiz_reset_tx_pll_and_datapath_in (1'b0),
    .gtwiz_reset_tx_datapath_in         (1'b0),
    .gtwiz_reset_rx_pll_and_datapath_in (1'b0),
    .gtwiz_reset_rx_datapath_in         (1'b0),
    .gtwiz_reset_rx_cdr_stable_out      (),
    .gtwiz_reset_tx_done_out            (tx_done),
    .gtwiz_reset_rx_done_out            (rx_done),
    .gtwiz_userdata_tx_in               (txdata_c),
    .gtwiz_userdata_rx_out              (rxdata_c),
    .gtrefclk00_in                      (refclk),
    .qpll0lock_out                      (qlock[0]),
    .qpll0outclk_out                    (),
    .qpll0outrefclk_out                 (),
    .gthrxn_in                          (rxn_c),
    .gthrxp_in                          (rxp_c),
    .loopback_in                        (lb_c),
    .rxgearboxslip_in                   (rxslip_c),
    .rxlpmen_in                         (lpm_c),
    .rxpmareset_in                      (pmareset_c),
    .rxpolarity_in                      (rxpol_c),
    .rxusrclk_in                        (rxusrclk_c),
    .rxusrclk2_in                       (rxusrclk2_c),
    .txdiffctrl_in                      (diff_c),
    .txheader_in                        (txheader_c),
    .txpolarity_in                      (txpol_c),
    .txpostcursor_in                    (post_c),
    .txprecursor_in                     (pre_c),
    .txsequence_in                      (28'd0),
    .gthtxn_out                         (txn_c),
    .gthtxp_out                         (txp_c),
    .gtpowergood_out                    (pg_c),
    .rxcdrlock_out                      (rxcdrlock_c),
    .rxdatavalid_out                    (rxdatavalid_c),
    .rxheader_out                       (rxheader_c),
    .rxheadervalid_out                  (rxheadervalid_c),
    .rxoutclk_out                       (rxoutclk_c),
    .rxpmaresetdone_out                 (rxpmaresetdone),
    .rxprgdivresetdone_out              (rxprgdivresetdone),
    .rxresetdone_out                    (rxresetdone_c),
    .rxstartofseq_out                   (),
    .txpmaresetdone_out                 (txpmaresetdone),
    .txprgdivresetdone_out              (txprgdivresetdone)
);
assign qlock[3:1] = '0;

endmodule

`resetall
