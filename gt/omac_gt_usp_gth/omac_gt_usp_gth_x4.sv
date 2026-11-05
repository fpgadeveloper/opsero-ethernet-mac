// SPDX-License-Identifier: MIT
//
// omac_gt_usp_gth_x4 - four UltraScale+ GTH channels of one quad for omac_40g
// (40GBASE-R4): the gtwizard_ultrascale IP made by gen_gt.tcl omac_gen_gth_x4
// (module omac_gth_40g) in 64B/66B asynchronous gearbox mode, plus the
// reference clock buffer, the per-lane RX user clocks and the omac GT-side
// conventions:
//   * lanes: port lane l (gt_tx_* / gt_rx_* / gth_* / polarity bit l) is the
//     gtwizard channel CH_OF_LANE[2l +: 2] (the IP numbers its channels in
//     ascending site order, e.g. X0Y12 = 0 ... X0Y15 = 3). The design sets it
//     from its board's lane order; the default is an example (lanes 0..3 on
//     sites X0Y14 X0Y13 X0Y15 X0Y12 = channels 2 1 3 0). omac_40g does not
//     depend on the order (the receiver reorders by marker), but with the
//     board's map omac_40g PCS lane l goes out on QSFP lane l
//   * IEEE bit order on the omac side (BIT_REVERSE = 1, see omac_gt_usp_gth)
//   * TX: one user clock for all lanes (the master channel's helper in the core;
//     TX buffers on), tx_usrclk2 = the omac `clk`
//   * RX: every channel has its own user clock from its own RXOUTCLK (two
//     BUFG_GT per lane: RXUSRCLK 312.5 MHz, RXUSRCLK2 156.25 MHz), so each lane's
//     gearbox output stays in its own recovered clock; rx_usrclk2[l] = the
//     omac gt_rx_clk[l]
//   * readiness: gt_tx_ready = TX reset done && TX user clock active;
//     gt_rx_ready = RX reset done && all four RX user clocks active
//   * the omac watchdog's gt_rx_reset_req drives the RX datapath reset (all lanes)
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_gt_usp_gth_x4 #(
    parameter bit       BIT_REVERSE = 1'b1,
    parameter bit [7:0] CH_OF_LANE  = {2'd0, 2'd3, 2'd1, 2'd2}   // lane 3..0 -> channel index
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
    output wire logic         tx_usrclk2,      // = omac clk
    output wire logic         gt_tx_ready,
    input  wire logic [7:0]   gt_tx_hdr,
    input  wire logic [255:0] gt_tx_data,
    output wire logic [3:0]   rx_usrclk2,      // = omac gt_rx_clk
    output wire logic         gt_rx_ready,
    output wire logic [3:0]   gt_rx_valid,
    output wire logic [7:0]   gt_rx_hdr,
    output wire logic [255:0] gt_rx_data,
    input  wire logic [3:0]   gt_rx_slip,
    input  wire logic         gt_rx_reset_req,
    input  wire logic [2:0]   gt_loopback,

    // transceiver settings (static)
    input  wire logic [3:0]   tx_polarity,
    input  wire logic [3:0]   rx_polarity,
    input  wire logic [4:0]   tx_diffctrl,     // e.g. 5'b11000, all lanes
    input  wire logic [4:0]   tx_postcursor,
    input  wire logic [4:0]   tx_precursor,
    input  wire logic         rx_lpmen,        // 0: DFE (cables), 1: LPM

    output wire logic [3:0]   gt_powergood
);

wire refclk;
IBUFDS_GTE4 #(
    .REFCLK_EN_TX_PATH (1'b0),
    .REFCLK_HROW_CK_SEL(2'b00),
    .REFCLK_ICNTL_RX   (2'b00)
) u_refclk_buf (.I(refclk_p), .IB(refclk_n), .CEB(1'b0), .O(refclk), .ODIV2());

// ---------------- per-channel vectors of the core (channel index c) ----------------
wire [255:0] txdata_c, rxdata_c;
wire [23:0]  txheader_c, rxheader_c;
wire [7:0]   rxdatavalid_c, rxheadervalid_c;
wire [3:0]   rxslip_c, rxpol_c, txpol_c, rxp_c, rxn_c, txp_c, txn_c, pg_c;
wire [3:0]   rxoutclk_c, rxusrclk_c, rxusrclk2_c, rx_active_c;
wire [3:0]   txpmaresetdone, rxpmaresetdone, txprgdivresetdone, rxprgdivresetdone;
wire         tx_done, rx_done, tx_active;

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
    assign rxp_c[C]             = gth_rxp[l];
    assign rxn_c[C]             = gth_rxn[l];
    assign gth_txp[l]           = txp_c[C];
    assign gth_txn[l]           = txn_c[C];
    assign gt_powergood[l]      = pg_c[C];
    assign rx_usrclk2[l]        = rxusrclk2_c[C];
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
assign gt_rx_ready = rx_done && (&rx_active_c);

omac_gth_40g u_gt (
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
    .gtwiz_reset_rx_datapath_in         (gt_rx_reset_req),
    .gtwiz_reset_rx_cdr_stable_out      (),
    .gtwiz_reset_tx_done_out            (tx_done),
    .gtwiz_reset_rx_done_out            (rx_done),
    .gtwiz_userdata_tx_in               (txdata_c),
    .gtwiz_userdata_rx_out              (rxdata_c),
    .gtrefclk00_in                      (refclk),
    .qpll0outclk_out                    (),
    .qpll0outrefclk_out                 (),
    .gthrxn_in                          (rxn_c),
    .gthrxp_in                          (rxp_c),
    .loopback_in                        ({4{gt_loopback}}),
    .rxgearboxslip_in                   (rxslip_c),
    .rxlpmen_in                         ({4{rx_lpmen}}),
    .rxpolarity_in                      (rxpol_c),
    .rxusrclk_in                        (rxusrclk_c),
    .rxusrclk2_in                       (rxusrclk2_c),
    .txdiffctrl_in                      ({4{tx_diffctrl}}),
    .txheader_in                        (txheader_c),
    .txpolarity_in                      (txpol_c),
    .txpostcursor_in                    ({4{tx_postcursor}}),
    .txprecursor_in                     ({4{tx_precursor}}),
    .txsequence_in                      (28'd0),
    .gthtxn_out                         (txn_c),
    .gthtxp_out                         (txp_c),
    .gtpowergood_out                    (pg_c),
    .rxdatavalid_out                    (rxdatavalid_c),
    .rxheader_out                       (rxheader_c),
    .rxheadervalid_out                  (rxheadervalid_c),
    .rxoutclk_out                       (rxoutclk_c),
    .rxpmaresetdone_out                 (rxpmaresetdone),
    .rxprgdivresetdone_out              (rxprgdivresetdone),
    .rxstartofseq_out                   (),
    .txpmaresetdone_out                 (txpmaresetdone),
    .txprgdivresetdone_out              (txprgdivresetdone)
);

endmodule

`resetall
