// SPDX-License-Identifier: MIT
//
// omac_10g_quad_gth_top - synthesis-only top: four omac_10g with the timestamp
// hooks (TS_EN = 1) on omac_gt_usp_gth_quad (the gtwizard IP from
// gt/omac_gt_usp_gth/gen_gt.tcl omac_gen_gth_quad, example quad X0Y12-X0Y15 of an
// xczu7ev): four independent 10GBASE-R ports on one quad, one TX user clock, a
// per-lane recovered clock and RX reset. The time value is a free-running
// counter in the TX user clock, gray-coded into each recovered clock, as a
// design would do it. User sides on top-level ports (out-of-context check).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_quad_gth_top (
    input  wire logic         refclk_p,
    input  wire logic         refclk_n,
    input  wire logic         freerun_clk,
    input  wire logic         reset_all,
    input  wire logic [3:0]   gth_rxp,
    input  wire logic [3:0]   gth_rxn,
    output wire logic [3:0]   gth_txp,
    output wire logic [3:0]   gth_txn,

    output wire logic         clk,
    input  wire logic [3:0]   rst,
    input  wire logic [255:0] s_axis_tx_tdata,
    input  wire logic [31:0]  s_axis_tx_tkeep,
    input  wire logic [3:0]   s_axis_tx_tvalid,
    output wire logic [3:0]   s_axis_tx_tready,
    input  wire logic [3:0]   s_axis_tx_tlast,
    output wire logic [255:0] m_axis_rx_tdata,
    output wire logic [31:0]  m_axis_rx_tkeep,
    output wire logic [3:0]   m_axis_rx_tvalid,
    output wire logic [3:0]   m_axis_rx_tlast,
    output wire logic [3:0]   m_axis_rx_tuser,
    output wire logic [63:0]  m_axis_rx_ts,
    output wire logic [3:0]   tx_ts_valid,
    output wire logic [63:0]  tx_ts_val,
    input  wire logic [15:0]  ctl,
    output wire logic [31:0]  stat,
    output wire logic [3:0]   rx_ready
);

wire         tx_ready;
wire [3:0]   rx_clk, rx_valid, rx_slip, rx_reset_req;
wire [7:0]   tx_hdr, rx_hdr;
wire [255:0] tx_data, rx_data;
wire [11:0]  loopback;

omac_gt_usp_gth_quad u_gt (
    .refclk_p(refclk_p), .refclk_n(refclk_n), .freerun_clk(freerun_clk), .reset_all(reset_all),
    .gth_rxp(gth_rxp), .gth_rxn(gth_rxn), .gth_txp(gth_txp), .gth_txn(gth_txn),
    .tx_usrclk2(clk), .gt_tx_ready(tx_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data),
    .rx_usrclk2(rx_clk), .gt_rx_ready(rx_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
    .gt_rx_data(rx_data), .gt_rx_slip(rx_slip), .gt_rx_reset_req(rx_reset_req), .gt_loopback(loopback),
    .tx_polarity(4'd0), .rx_polarity(4'd0), .tx_diffctrl({4{5'b11000}}), .tx_postcursor(20'd0),
    .tx_precursor(20'd0), .rx_lpmen(4'd0), .gt_powergood(), .qpll_lock(), .rx_cdr_lock(), .rx_reset_busy(), .refclk_mon());

// time value: 16-bit cycle counter in clk, gray-coded into each recovered clock
logic [15:0] tick = '0, tick_g = '0;
always_ff @(posedge clk) begin
    tick   <= tick + 1'b1;
    tick_g <= tick ^ (tick >> 1);
end

for (genvar l = 0; l < 4; l++) begin : g_port
    (* ASYNC_REG = "TRUE" *) logic [15:0] g0 = '0, g1 = '0;
    logic [15:0] rx_tick = '0;
    always_ff @(posedge rx_clk[l]) begin
        g0 <= tick_g;
        g1 <= g0;
        for (int i = 0; i < 16; i++) rx_tick[i] <= ^(g1 >> i);
    end
    omac_10g #(.TS_EN(1'b1), .TS_W(16)) u_mac (
        .clk(clk), .rst(rst[l]),
        .s_axis_tx_tdata(s_axis_tx_tdata[64*l +: 64]), .s_axis_tx_tkeep(s_axis_tx_tkeep[8*l +: 8]),
        .s_axis_tx_tvalid(s_axis_tx_tvalid[l]), .s_axis_tx_tready(s_axis_tx_tready[l]),
        .s_axis_tx_tlast(s_axis_tx_tlast[l]), .s_axis_tx_tuser(1'b0),
        .m_axis_rx_tdata(m_axis_rx_tdata[64*l +: 64]), .m_axis_rx_tkeep(m_axis_rx_tkeep[8*l +: 8]),
        .m_axis_rx_tvalid(m_axis_rx_tvalid[l]), .m_axis_rx_tlast(m_axis_rx_tlast[l]),
        .m_axis_rx_tuser(m_axis_rx_tuser[l]),
        .ctl_tx_enable(ctl[0]), .ctl_rx_enable(ctl[1]), .ctl_loopback(ctl[2 + l]), .ctl_tx_fault(1'b0),
        .ctl_pause_tx_honour(ctl[6]), .ctl_tx_pause_send(ctl[7 + l]), .ctl_tx_pause_quanta(16'hFFFF),
        .ctl_tx_pause_refresh(16'h8000), .ctl_mac_addr(48'h0000_0000_0a00 + l),
        .stat_link_up(stat[8*l]), .stat_block_lock(stat[8*l + 1]), .stat_hi_ber(stat[8*l + 2]),
        .stat_local_fault(stat[8*l + 3]), .stat_remote_fault(stat[8*l + 4]), .stat_rx_pause_req(stat[8*l + 5]),
        .stat_rx_pause_quanta(), .stat_tx_pause_active(stat[8*l + 6]),
        .ev_tx_frame(stat[8*l + 7]), .ev_tx_pause(), .ev_tx_underflow(), .ev_tx_abort(), .ev_rx_frame_good(),
        .ev_rx_frame_bad(), .ev_rx_fcs_error(), .ev_rx_runt(), .ev_rx_oversize(), .ev_rx_pause(),
        .ev_rx_bad_block(), .ev_rx_sequence_error(),
        .gt_tx_ready(tx_ready), .gt_tx_hdr(tx_hdr[2*l +: 2]), .gt_tx_data(tx_data[64*l +: 64]),
        .gt_loopback(loopback[3*l +: 3]),
        .gt_rx_clk(rx_clk[l]), .gt_rx_ready(rx_ready[l]), .gt_rx_valid(rx_valid[l]), .gt_rx_hdr(rx_hdr[2*l +: 2]),
        .gt_rx_data(rx_data[64*l +: 64]), .gt_rx_slip(rx_slip[l]), .gt_rx_reset_req(rx_reset_req[l]),
        .tx_ts_in(tick), .tx_ts_valid(tx_ts_valid[l]), .tx_ts_val(tx_ts_val[16*l +: 16]), .tx_ts_lane4(),
        .tx_ts_user(), .rx_ts_in(rx_tick), .m_axis_rx_ts(m_axis_rx_ts[16*l +: 16]), .m_axis_rx_ts_lane4());
end

endmodule

`resetall
