// SPDX-License-Identifier: MIT
//
// omac_gt_usp_gth - one UltraScale+ GTH channel for a 64B/66B omac IP
// (omac_10g at 10GBASE-R): the gtwizard_ultrascale IP made by gen_gt.tcl
// (module GT_IP_NAME, default omac_gth_10g) in 64B/66B asynchronous gearbox
// mode, plus the reference clock buffer and the omac GT-side conventions:
//   * IEEE bit order on the omac side: the GT gearbox sends MSB first, so the
//     64 data bits are reversed and the two header bits swapped in both
//     directions (BIT_REVERSE = 1; 0 passes them straight, for experiments)
//   * TXSEQUENCE tied to 0 (asynchronous gearbox), rx valid = RXDATAVALID[0] &
//     RXHEADERVALID[0]
//   * user clocks: tx_usrclk2 (= the omac `clk`) and rx_usrclk2 (`gt_rx_clk`),
//     156.25 MHz, from the core's user clocking helpers, held in reset until
//     the PMA and the programmable divider are out of reset
//   * readiness: gt_tx_ready / gt_rx_ready = reset done && user clock active
//   * the omac watchdog's gt_rx_reset_req drives the RX datapath reset
// The channel location comes from the IP (gen_gt.tcl `channel`); the serial
// pins need no constraint (the IP's LOC fixes them), the reference clock pins
// need a PACKAGE_PIN on refclk_p (the board's pin for MGTREFCLK0 of the quad).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_gt_usp_gth #(
    parameter bit BIT_REVERSE = 1'b1
) (
    // reference clock (MGTREFCLK0 of the channel's quad), 156.25 MHz
    input  wire logic        refclk_p,
    input  wire logic        refclk_n,
    // free-running clock for the reset controller (gen_gt.tcl freerun_mhz)
    input  wire logic        freerun_clk,
    // reset everything (assert after the reference clock is stable)
    input  wire logic        reset_all,

    // serial pins
    input  wire logic        gth_rxp,
    input  wire logic        gth_rxn,
    output wire logic        gth_txp,
    output wire logic        gth_txn,

    // omac GT side
    output wire logic        tx_usrclk2,      // = omac clk
    output wire logic        gt_tx_ready,
    input  wire logic [1:0]  gt_tx_hdr,
    input  wire logic [63:0] gt_tx_data,
    output wire logic        rx_usrclk2,      // = omac gt_rx_clk
    output wire logic        gt_rx_ready,
    output wire logic        gt_rx_valid,
    output wire logic [1:0]  gt_rx_hdr,
    output wire logic [63:0] gt_rx_data,
    input  wire logic        gt_rx_slip,
    input  wire logic        gt_rx_reset_req,
    input  wire logic [2:0]  gt_loopback,

    // transceiver settings (static; see the GTH user guide for the codes)
    input  wire logic        tx_polarity,
    input  wire logic        rx_polarity,
    input  wire logic [4:0]  tx_diffctrl,     // e.g. 5'b11000
    input  wire logic [4:0]  tx_postcursor,   // e.g. 5'b00000
    input  wire logic [4:0]  tx_precursor,    // e.g. 5'b00000
    input  wire logic        rx_lpmen,        // 0: DFE (cables), 1: LPM

    // status
    output wire logic        gt_powergood
);

wire refclk;
IBUFDS_GTE4 #(
    .REFCLK_EN_TX_PATH (1'b0),
    .REFCLK_HROW_CK_SEL(2'b00),
    .REFCLK_ICNTL_RX   (2'b00)
) u_refclk_buf (.I(refclk_p), .IB(refclk_n), .CEB(1'b0), .O(refclk), .ODIV2());

wire [63:0] txdata_gt, rxdata_gt;
wire [5:0]  rxheader_gt;
wire [1:0]  rxdatavalid_gt, rxheadervalid_gt;
wire [5:0]  txheader_gt;
wire        tx_done, rx_done, tx_active, rx_active;
wire        txpmaresetdone, rxpmaresetdone, txprgdivresetdone, rxprgdivresetdone;

for (genvar i = 0; i < 64; i++) begin : g_bits
    assign txdata_gt[i]  = BIT_REVERSE ? gt_tx_data[63 - i] : gt_tx_data[i];
    assign gt_rx_data[i] = BIT_REVERSE ? rxdata_gt[63 - i]  : rxdata_gt[i];
end
assign txheader_gt = {4'd0, BIT_REVERSE ? {gt_tx_hdr[0], gt_tx_hdr[1]} : gt_tx_hdr};
assign gt_rx_hdr   = BIT_REVERSE ? {rxheader_gt[0], rxheader_gt[1]} : rxheader_gt[1:0];
assign gt_rx_valid = rxdatavalid_gt[0] && rxheadervalid_gt[0];

assign gt_tx_ready = tx_done && tx_active;
assign gt_rx_ready = rx_done && rx_active;

omac_gth_10g u_gt (
    .gtwiz_userclk_tx_reset_in          (~(txprgdivresetdone && txpmaresetdone)),
    .gtwiz_userclk_tx_srcclk_out        (),
    .gtwiz_userclk_tx_usrclk_out        (),
    .gtwiz_userclk_tx_usrclk2_out       (tx_usrclk2),
    .gtwiz_userclk_tx_active_out        (tx_active),
    .gtwiz_userclk_rx_reset_in          (~(rxprgdivresetdone && rxpmaresetdone)),
    .gtwiz_userclk_rx_srcclk_out        (),
    .gtwiz_userclk_rx_usrclk_out        (),
    .gtwiz_userclk_rx_usrclk2_out       (rx_usrclk2),
    .gtwiz_userclk_rx_active_out        (rx_active),
    .gtwiz_reset_clk_freerun_in         (freerun_clk),
    .gtwiz_reset_all_in                 (reset_all),
    .gtwiz_reset_tx_pll_and_datapath_in (1'b0),
    .gtwiz_reset_tx_datapath_in         (1'b0),
    .gtwiz_reset_rx_pll_and_datapath_in (1'b0),
    .gtwiz_reset_rx_datapath_in         (gt_rx_reset_req),
    .gtwiz_reset_rx_cdr_stable_out      (),
    .gtwiz_reset_tx_done_out            (tx_done),
    .gtwiz_reset_rx_done_out            (rx_done),
    .gtwiz_userdata_tx_in               (txdata_gt),
    .gtwiz_userdata_rx_out              (rxdata_gt),
    .gtrefclk00_in                      (refclk),
    .qpll0outclk_out                    (),
    .qpll0outrefclk_out                 (),
    .gthrxn_in                          (gth_rxn),
    .gthrxp_in                          (gth_rxp),
    .loopback_in                        (gt_loopback),
    .rxgearboxslip_in                   (gt_rx_slip),
    .rxlpmen_in                         (rx_lpmen),
    .rxpolarity_in                      (rx_polarity),
    .txdiffctrl_in                      (tx_diffctrl),
    .txheader_in                        (txheader_gt),
    .txpolarity_in                      (tx_polarity),
    .txpostcursor_in                    (tx_postcursor),
    .txprecursor_in                     (tx_precursor),
    .txsequence_in                      (7'd0),
    .gthtxn_out                         (gth_txn),
    .gthtxp_out                         (gth_txp),
    .gtpowergood_out                    (gt_powergood),
    .rxdatavalid_out                    (rxdatavalid_gt),
    .rxheader_out                       (rxheader_gt),
    .rxheadervalid_out                  (rxheadervalid_gt),
    .rxpmaresetdone_out                 (rxpmaresetdone),
    .rxprgdivresetdone_out              (rxprgdivresetdone),
    .rxstartofseq_out                   (),
    .txpmaresetdone_out                 (txpmaresetdone),
    .txprgdivresetdone_out              (txprgdivresetdone)
);

endmodule

`resetall
