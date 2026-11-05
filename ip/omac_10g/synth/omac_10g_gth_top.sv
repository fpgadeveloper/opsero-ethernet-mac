// SPDX-License-Identifier: MIT
//
// omac_10g_gth_top - synthesis-only top: omac_10g + omac_gt_usp_gth (the
// gtwizard IP from gt/omac_gt_usp_gth/gen_gt.tcl, example channel X0Y14 of an xczu7ev)
// with the user side on top-level ports. Checks that the GT-side interface
// types, widths and clocks of the two fit (out-of-context synthesis).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_gth_top (
    input  wire logic        refclk_p,
    input  wire logic        refclk_n,
    input  wire logic        freerun_clk,
    input  wire logic        reset_all,
    input  wire logic        gth_rxp,
    input  wire logic        gth_rxn,
    output wire logic        gth_txp,
    output wire logic        gth_txn,

    output wire logic        clk,
    input  wire logic        rst,
    input  wire logic [63:0] s_axis_tx_tdata,
    input  wire logic [7:0]  s_axis_tx_tkeep,
    input  wire logic        s_axis_tx_tvalid,
    output wire logic        s_axis_tx_tready,
    input  wire logic        s_axis_tx_tlast,
    input  wire logic [0:0]  s_axis_tx_tuser,
    output wire logic [63:0] m_axis_rx_tdata,
    output wire logic [7:0]  m_axis_rx_tkeep,
    output wire logic        m_axis_rx_tvalid,
    output wire logic        m_axis_rx_tlast,
    output wire logic [0:0]  m_axis_rx_tuser,
    input  wire logic [15:0] ctl,
    input  wire logic [47:0] ctl_mac_addr,
    output wire logic [7:0]  stat,
    output wire logic [11:0] ev
);

wire        tx_ready, rx_clk, rx_ready, rx_valid, rx_slip, rx_reset_req;
wire [1:0]  tx_hdr, rx_hdr;
wire [63:0] tx_data, rx_data;
wire [2:0]  loopback;
wire [15:0] pq;

omac_gt_usp_gth u_gt (
    .refclk_p(refclk_p), .refclk_n(refclk_n), .freerun_clk(freerun_clk), .reset_all(reset_all),
    .gth_rxp(gth_rxp), .gth_rxn(gth_rxn), .gth_txp(gth_txp), .gth_txn(gth_txn),
    .tx_usrclk2(clk), .gt_tx_ready(tx_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data),
    .rx_usrclk2(rx_clk), .gt_rx_ready(rx_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
    .gt_rx_data(rx_data), .gt_rx_slip(rx_slip), .gt_rx_reset_req(rx_reset_req), .gt_loopback(loopback),
    .tx_polarity(1'b0), .rx_polarity(1'b0), .tx_diffctrl(5'b11000), .tx_postcursor(5'd0),
    .tx_precursor(5'd0), .rx_lpmen(1'b0), .gt_powergood());

omac_10g u_mac (
    .clk(clk), .rst(rst),
    .s_axis_tx_tdata(s_axis_tx_tdata), .s_axis_tx_tkeep(s_axis_tx_tkeep), .s_axis_tx_tvalid(s_axis_tx_tvalid),
    .s_axis_tx_tready(s_axis_tx_tready), .s_axis_tx_tlast(s_axis_tx_tlast), .s_axis_tx_tuser(s_axis_tx_tuser),
    .m_axis_rx_tdata(m_axis_rx_tdata), .m_axis_rx_tkeep(m_axis_rx_tkeep), .m_axis_rx_tvalid(m_axis_rx_tvalid),
    .m_axis_rx_tlast(m_axis_rx_tlast), .m_axis_rx_tuser(m_axis_rx_tuser),
    .ctl_tx_enable(ctl[0]), .ctl_rx_enable(ctl[1]), .ctl_loopback(ctl[2]), .ctl_tx_fault(ctl[3]),
    .ctl_pause_tx_honour(ctl[4]), .ctl_tx_pause_send(ctl[5]), .ctl_tx_pause_quanta({ctl[15:8], 8'h00}),
    .ctl_tx_pause_refresh({1'b0, ctl[15:9], 8'h00}), .ctl_mac_addr(ctl_mac_addr),
    .stat_link_up(stat[0]), .stat_block_lock(stat[1]), .stat_hi_ber(stat[2]), .stat_local_fault(stat[3]),
    .stat_remote_fault(stat[4]), .stat_rx_pause_req(stat[5]), .stat_rx_pause_quanta(pq),
    .stat_tx_pause_active(stat[6]),
    .ev_tx_frame(ev[0]), .ev_tx_pause(ev[1]), .ev_tx_underflow(ev[2]), .ev_tx_abort(ev[3]),
    .ev_rx_frame_good(ev[4]), .ev_rx_frame_bad(ev[5]), .ev_rx_fcs_error(ev[6]), .ev_rx_runt(ev[7]),
    .ev_rx_oversize(ev[8]), .ev_rx_pause(ev[9]), .ev_rx_bad_block(ev[10]), .ev_rx_sequence_error(ev[11]),
    .gt_tx_ready(tx_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data), .gt_loopback(loopback),
    .gt_rx_clk(rx_clk), .gt_rx_ready(rx_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
    .gt_rx_data(rx_data), .gt_rx_slip(rx_slip), .gt_rx_reset_req(rx_reset_req));
assign stat[7] = ^pq;

endmodule

`resetall
