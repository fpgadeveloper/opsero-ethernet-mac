// SPDX-License-Identifier: MIT
//
// omac_40g - 40GBASE-R4 Ethernet MAC + PCS (IEEE 802.3 clauses 81 and 82), four
// lanes at 10.3125 Gb/s, 256-bit AXI-Stream on one user clock. Implements the
// omac boundary contract (docs/interface.md): user side in `clk` (= the
// transceiver TX user clock, 156.25 MHz), GT side = four lanes of 66-bit blocks
// to transceivers in 64B/66B asynchronous gearbox mode (gt/omac_gt_usp_gth,
// omac_gt_usp_gth_x4 for four UltraScale+ GTH channels).
//
//   clk                    TX: AXIS -> mac_tx -> RS (faults) -> pcs_tx (encode,
//                          scramble, distribute, alignment markers) -> gt_tx_*[4]
//   gt_rx_clk[p] (each)    lane_rx: block lock + slip, AM lock, BIP -> lane FIFO
//   rclk = gt_rx_clk[RX_CLK_LANE]
//                          pcs_rx (deskew, reorder, AM removal, BER, descramble,
//                          decode) -> RS fault detect -> mac_rx -> two FIFO banks
//   clk                    RX: the banks are read alternately -> AXIS RX
//   PAUSE timers, watchdog, status / event crossing in clk
//
// The four lanes may arrive in any physical order and with up to DESKEW_MAX
// blocks of skew: every receiver finds the PCS lane number in the alignment
// markers. The transmit lane order is therefore free (gt_tx_* lane l carries PCS
// lane l); connect the lanes in whatever order the board routes them.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_40g #(
    parameter int          DATA_WIDTH      = 256,
    parameter int          MIN_FRAME       = 64,
    parameter int          MAX_FRAME       = 9600,
    parameter bit          PAUSE_EN        = 1'b1,
    parameter bit          TX_PAD          = 1'b1,      // 0 only for tests (runts)
    parameter int          DIC_MAX         = 7,         // deficit idle count range (gaps 12-DIC_MAX .. 19-DIC_MAX)
    parameter int          AM_PERIOD       = 16384,     // blocks per lane per marker (IEEE: 16384); smaller only in tests
    parameter int          DESKEW_MAX      = 32,        // lane skew tolerated, in blocks (6.4 ns each; IEEE: 180 ns)
    parameter int          LANE_FIFO_DEPTH = 64,        // per-lane deskew + clock-crossing FIFO
    parameter int          RX_CLK_LANE     = 0,         // physical lane whose recovered clock runs the RX PCS + MAC
    parameter int          SLIP_WAIT       = 256,
    parameter int          BER_TIMER_CLKS  = 195313,    // 1.25 ms at 156.25 MHz
    parameter int          BER_THRESH      = 97,
    parameter int          RX_WATCHDOG     = 2097152,   // clk cycles without alignment before gt_rx_reset_req
    parameter int          RX_FIFO_DEPTH   = 64,        // RX clock-crossing FIFO entries (two banks)
    parameter logic [2:0]  LOOPBACK_MODE   = 3'b010,    // GT near-end PMA loopback
    parameter logic [57:0] SCR_INIT        = '1
) (
    input  wire logic         clk,
    input  wire logic         rst,

    // transmit AXI-Stream (frames without FCS)
    input  wire logic [255:0] s_axis_tx_tdata,
    input  wire logic [31:0]  s_axis_tx_tkeep,
    input  wire logic         s_axis_tx_tvalid,
    output wire logic         s_axis_tx_tready,
    input  wire logic         s_axis_tx_tlast,
    input  wire logic [0:0]   s_axis_tx_tuser,

    // receive AXI-Stream (FCS stripped, no tready)
    output logic      [255:0] m_axis_rx_tdata,
    output logic      [31:0]  m_axis_rx_tkeep,
    output logic              m_axis_rx_tvalid,
    output logic              m_axis_rx_tlast,
    output logic      [0:0]   m_axis_rx_tuser,

    // control
    input  wire logic         ctl_tx_enable,
    input  wire logic         ctl_rx_enable,
    input  wire logic         ctl_loopback,
    input  wire logic         ctl_tx_fault,
    input  wire logic         ctl_pause_tx_honour,
    input  wire logic         ctl_tx_pause_send,
    input  wire logic [15:0]  ctl_tx_pause_quanta,
    input  wire logic [15:0]  ctl_tx_pause_refresh,
    input  wire logic [47:0]  ctl_mac_addr,

    // status
    output logic              stat_link_up,
    output wire logic         stat_block_lock,
    output wire logic         stat_hi_ber,
    output wire logic         stat_local_fault,
    output wire logic         stat_remote_fault,
    output wire logic         stat_rx_pause_req,
    output logic      [15:0]  stat_rx_pause_quanta,
    output wire logic         stat_tx_pause_active,
    // status, 40G only (physical lane p at bit p / bits [2p +: 2])
    output wire logic [3:0]   stat_lane_block_lock,
    output wire logic [3:0]   stat_lane_am_lock,
    output wire logic [7:0]   stat_lane_map,
    output wire logic [6:0]   stat_lane_skew,

    // events
    output wire logic         ev_tx_frame,
    output wire logic         ev_tx_pause,
    output wire logic         ev_tx_underflow,
    output wire logic         ev_tx_abort,
    output wire logic         ev_rx_frame_good,
    output wire logic         ev_rx_frame_bad,
    output wire logic         ev_rx_fcs_error,
    output wire logic         ev_rx_runt,
    output wire logic         ev_rx_oversize,
    output wire logic         ev_rx_pause,
    output wire logic         ev_rx_bad_block,
    output wire logic         ev_rx_sequence_error,
    // events, 40G only
    output wire logic [3:0]   ev_rx_bip_error,
    output wire logic         ev_rx_overflow,
    output wire logic         ev_rx_skew_fail,

    // GT transmit (clk), lane l = [2l +: 2] / [64l +: 64]
    input  wire logic         gt_tx_ready,
    output wire logic [7:0]   gt_tx_hdr,
    output wire logic [255:0] gt_tx_data,
    output logic      [2:0]   gt_loopback,

    // GT receive, physical lane p
    input  wire logic [3:0]   gt_rx_clk,
    input  wire logic         gt_rx_ready,
    input  wire logic [3:0]   gt_rx_valid,
    input  wire logic [7:0]   gt_rx_hdr,
    input  wire logic [255:0] gt_rx_data,
    output wire logic [3:0]   gt_rx_slip,
    output logic              gt_rx_reset_req
);

import omac_pkg::*;

initial begin
    if (DATA_WIDTH != 256) $fatal(1, "omac_40g: DATA_WIDTH must be 256");
    if (RX_FIFO_DEPTH < 16 || (RX_FIFO_DEPTH & (RX_FIFO_DEPTH - 1)) != 0)
        $fatal(1, "omac_40g: RX_FIFO_DEPTH must be a power of two >= 16");
    if (LANE_FIFO_DEPTH < DESKEW_MAX + 16) $fatal(1, "omac_40g: LANE_FIFO_DEPTH must be >= DESKEW_MAX + 16");
    if (DESKEW_MAX > 127) $fatal(1, "omac_40g: DESKEW_MAX must be <= 127");
end

wire rclk = gt_rx_clk[RX_CLK_LANE];

// ======================= resets =======================
logic tx_ready_s, rx_ready_s;
omac_sync_bit #(.WIDTH(2)) u_sync_rdy (.clk(clk), .din({gt_tx_ready, gt_rx_ready}),
                                       .dout({tx_ready_s, rx_ready_s}));
logic tx_rst = 1'b1;
always_ff @(posedge clk) tx_rst <= rst || !tx_ready_s;

wire  rx_rst_any = rst || !gt_rx_ready || !gt_tx_ready;
logic rx_rst;        // rclk
omac_sync_reset u_rx_rst (.clk(rclk), .rst_in(rx_rst_any), .rst_out(rx_rst));
logic fifo_rd_rst = 1'b1;
always_ff @(posedge clk) fifo_rd_rst <= rst || !rx_ready_s || !tx_ready_s;

// ======================= lanes (gt_rx_clk[p]) =======================
logic [3:0]   l_lock, l_aml, l_bip, l_valid, l_rd;
logic         l_flush_wr, l_flush_rd;
logic [7:0]   l_id;
logic [271:0] l_data;

for (genvar p = 0; p < 4; p++) begin : g_lane
    logic        lrst, lfl;
    logic        ov, oam, oamk;
    logic [65:0] oblk;
    omac_sync_reset u_lrst (.clk(gt_rx_clk[p]), .rst_in(rx_rst_any), .rst_out(lrst));
    omac_sync_reset u_lfl (.clk(gt_rx_clk[p]), .rst_in(rx_rst_any || l_flush_wr), .rst_out(lfl));
    omac_40g_lane_rx #(.AM_PERIOD(AM_PERIOD), .SLIP_WAIT(SLIP_WAIT)) u_lane (
        .clk(gt_rx_clk[p]), .rst(lrst), .valid(gt_rx_valid[p]), .hdr(gt_rx_hdr[2*p +: 2]),
        .data(gt_rx_data[64*p +: 64]), .slip(gt_rx_slip[p]),
        .block_lock(l_lock[p]), .am_lock(l_aml[p]), .lane_id(l_id[2*p +: 2]), .ev_bip_error(l_bip[p]),
        .o_valid(ov), .o_am(oam), .o_amok(oamk), .o_blk(oblk));
    omac_async_fifo #(.WIDTH(68), .DEPTH(LANE_FIFO_DEPTH)) u_lfifo (
        .wr_clk(gt_rx_clk[p]), .wr_rst(lfl), .wr_en(ov), .wr_data({oamk, oam, oblk}), .wr_overflow(), .wr_free(),
        .rd_clk(rclk), .rd_rst(rx_rst || l_flush_rd), .rd_en(l_rd[p]), .rd_data(l_data[68*p +: 68]), .rd_valid(l_valid[p]));
end

// lane status into rclk (quasi-static levels; the lane id only changes while AM lock is low)
logic [3:0] c_lock, c_aml;
logic [7:0] c_id;
omac_sync_bit #(.WIDTH(16)) u_sync_lane (.clk(rclk), .din({l_id, l_aml, l_lock}), .dout({c_id, c_aml, c_lock}));

// ======================= PCS + MAC receive (rclk) =======================
logic         r_align, r_hi_ber, r_xv, r_bad_block, r_seq_err, r_skew_fail;
logic [255:0] r_xd;
logic [31:0]  r_xc;
logic [7:0]   r_map;
logic [6:0]   r_skew;

omac_40g_pcs_rx #(.DESKEW_MAX(DESKEW_MAX), .BER_TIMER_CLKS(BER_TIMER_CLKS), .BER_THRESH(BER_THRESH)) u_pcs_rx (
    .clk(rclk), .rst(rx_rst), .l_valid(l_valid), .l_data(l_data), .l_rd(l_rd),
    .flush_wr(l_flush_wr), .flush_rd(l_flush_rd),
    .l_block_lock(c_lock), .l_am_lock(c_aml), .l_lane_id(c_id),
    .align_status(r_align), .hi_ber(r_hi_ber), .lane_map(r_map), .skew(r_skew), .ev_skew_fail(r_skew_fail),
    .xvalid(r_xv), .xd(r_xd), .xc(r_xc), .ev_bad_block(r_bad_block), .ev_seq_error(r_seq_err));

// RS link fault detection on the four 8-byte columns (lanes 0-3 of each)
logic [1:0] r_link_fault;
omac_rs_fault #(.COLS(4)) u_rs_fault (
    .clk(rclk), .rst(rx_rst), .valid(r_xv),
    .d({r_xd[223:192], r_xd[159:128], r_xd[95:64], r_xd[31:0]}),
    .c({r_xc[27:24], r_xc[19:16], r_xc[11:8], r_xc[3:0]}), .link_fault(r_link_fault));

logic rx_enable_r;
omac_sync_bit u_sync_rxen (.clk(rclk), .din(ctl_rx_enable), .dout(rx_enable_r));

localparam int BD = RX_FIFO_DEPTH / 2;
localparam int FW = $clog2(BD) + 1;
logic          we0, we1, rv0, rv1, pop0, pop1;
logic [263:0]  wd0, wd1, rd0, rd1;
logic [FW-1:0] free0, free1;
logic          r_pause_ev;
logic [15:0]   r_pause_time;
logic          r_ev_good, r_ev_bad, r_ev_fcs, r_ev_runt, r_ev_over, r_ev_ovf;

omac_40g_mac_rx #(.MIN_FRAME(MIN_FRAME), .MAX_FRAME(MAX_FRAME), .FW(FW)) u_mac_rx (
    .clk(rclk), .rst(rx_rst), .xvalid(r_xv), .xd(r_xd), .xc(r_xc),
    .rx_enable(rx_enable_r), .mac_addr(ctl_mac_addr),
    .free0(free0), .free1(free1), .we0(we0), .wd0(wd0), .we1(we1), .wd1(wd1),
    .pause_ev(r_pause_ev), .pause_time(r_pause_time),
    .ev_good(r_ev_good), .ev_bad(r_ev_bad), .ev_fcs_error(r_ev_fcs), .ev_runt(r_ev_runt),
    .ev_oversize(r_ev_over), .ev_overflow(r_ev_ovf));

// two banks into clk, read alternately
omac_async_fifo #(.WIDTH(264), .DEPTH(BD)) u_bank0 (
    .wr_clk(rclk), .wr_rst(rx_rst), .wr_en(we0), .wr_data(wd0), .wr_overflow(), .wr_free(free0),
    .rd_clk(clk), .rd_rst(fifo_rd_rst), .rd_en(pop0), .rd_data(rd0), .rd_valid(rv0));
omac_async_fifo #(.WIDTH(264), .DEPTH(BD)) u_bank1 (
    .wr_clk(rclk), .wr_rst(rx_rst), .wr_en(we1), .wr_data(wd1), .wr_overflow(), .wr_free(free1),
    .rd_clk(clk), .rd_rst(fifo_rd_rst), .rd_en(pop1), .rd_data(rd1), .rd_valid(rv1));

logic        turn = 1'b0;
wire         bv = turn ? rv1 : rv0;
wire [263:0] bd = turn ? rd1 : rd0;
assign pop0 = !turn && rv0;
assign pop1 = turn && rv1;

always_ff @(posedge clk) begin
    m_axis_rx_tvalid <= bv;
    m_axis_rx_tdata  <= bd[255:0];
    m_axis_rx_tkeep  <= (bd[261:256] >= 6'd32) ? 32'hFFFF_FFFF : 32'((33'h1 << bd[261:256]) - 1);
    m_axis_rx_tlast  <= bd[262];
    m_axis_rx_tuser  <= bd[263];
    if (bv) turn <= !turn;
    if (fifo_rd_rst) begin
        turn <= 1'b0;
        m_axis_rx_tvalid <= 1'b0;
    end
end

// events into clk
omac_cdc_event #(.N(10)) u_cdc_ev (
    .s_clk(rclk),
    .s_ev({r_skew_fail, r_ev_ovf, r_seq_err, r_bad_block, r_pause_ev, r_ev_over, r_ev_runt, r_ev_fcs,
           r_ev_bad, r_ev_good}),
    .m_clk(clk), .m_rst(tx_rst),
    .m_ev({ev_rx_skew_fail, ev_rx_overflow, ev_rx_sequence_error, ev_rx_bad_block, ev_rx_pause,
           ev_rx_oversize, ev_rx_runt, ev_rx_fcs_error, ev_rx_frame_bad, ev_rx_frame_good}));
for (genvar p = 0; p < 4; p++) begin : g_bip_ev
    omac_cdc_event #(.N(1)) u_cdc_bip (.s_clk(gt_rx_clk[p]), .s_ev(l_bip[p]), .m_clk(clk), .m_rst(tx_rst),
                                      .m_ev(ev_rx_bip_error[p]));
end

// status levels into clk
logic s_lock, s_hiber;
logic [1:0] s_fault;
omac_sync_bit #(.WIDTH(4)) u_sync_stat (.clk(clk),
    .din({r_link_fault, r_hi_ber, r_align}), .dout({s_fault, s_hiber, s_lock}));
omac_sync_bit #(.WIDTH(23)) u_sync_lstat (.clk(clk), .din({r_skew, r_map, l_aml, l_lock}),
    .dout({stat_lane_skew, stat_lane_map, stat_lane_am_lock, stat_lane_block_lock}));
assign stat_block_lock   = s_lock && rx_ready_s;
assign stat_hi_ber       = s_hiber;
assign stat_local_fault  = (s_fault == 2'd1) || !rx_ready_s;
assign stat_remote_fault = (s_fault == 2'd2);

always_ff @(posedge clk) begin
    stat_link_up <= stat_block_lock && !stat_hi_ber && !stat_local_fault && !stat_remote_fault &&
                    tx_ready_s;
end

// received PAUSE (rclk -> clk): toggle + quanta held stable
logic        r_ptog = 1'b0;
logic [15:0] r_pq = '0;
always_ff @(posedge rclk) begin
    if (r_pause_ev) begin
        r_ptog <= !r_ptog;
        r_pq   <= r_pause_time;
    end
end
logic p_tog_s, p_tog_d = 1'b0;
omac_sync_bit u_sync_ptog (.clk(clk), .din(r_ptog), .dout(p_tog_s));
logic p_load = 1'b0;
always_ff @(posedge clk) begin
    p_tog_d <= p_tog_s;
    p_load  <= PAUSE_EN && (p_tog_s != p_tog_d);
    if (p_tog_s != p_tog_d) stat_rx_pause_quanta <= r_pq;
    if (tx_rst) begin
        p_load <= 1'b0;
        stat_rx_pause_quanta <= '0;
    end
end

// ======================= PAUSE timers (clk) =======================
logic pq_req, pq_xon, pq_ack;
omac_pause #(.BIT_TIMES_PER_CLK(256)) u_pause (
    .clk(clk), .rst(tx_rst),
    .rx_load(p_load), .rx_quanta(stat_rx_pause_quanta), .rx_pause_req(stat_rx_pause_req),
    .tx_send(PAUSE_EN && ctl_tx_pause_send), .tx_refresh(ctl_tx_pause_refresh),
    .tx_req(pq_req), .tx_req_xon(pq_xon), .tx_ack(pq_ack), .tx_xoff_active(stat_tx_pause_active));

// ======================= transmit (clk) =======================
logic         tx_ce;
logic [255:0] m_xd;
logic [31:0]  m_xc;
omac_40g_mac_tx #(.TX_PAD(TX_PAD), .PAUSE_EN(PAUSE_EN), .DIC_MAX(DIC_MAX)) u_mac_tx (
    .clk(clk), .rst(tx_rst), .ce(tx_ce),
    .s_tdata(s_axis_tx_tdata), .s_tkeep(s_axis_tx_tkeep), .s_tvalid(s_axis_tx_tvalid),
    .s_tready(s_axis_tx_tready), .s_tlast(s_axis_tx_tlast), .s_tuser(s_axis_tx_tuser[0]),
    .tx_enable(ctl_tx_enable), .hold(ctl_pause_tx_honour && stat_rx_pause_req),
    .pause_req(pq_req), .pause_req_xon(pq_xon), .pause_ack(pq_ack),
    .pause_quanta(ctl_tx_pause_quanta), .mac_addr(ctl_mac_addr),
    .xd(m_xd), .xc(m_xc),
    .ev_frame(ev_tx_frame), .ev_pause(ev_tx_pause), .ev_underflow(ev_tx_underflow), .ev_abort(ev_tx_abort));

// RS transmit: link fault signalling (clause 81), per 8-byte column
localparam logic [63:0] LF_D   = {{4{XG_IDLE}}, LF_CODE, 16'h0000, XG_SEQ};
localparam logic [63:0] RF_D   = {{4{XG_IDLE}}, RF_CODE, 16'h0000, XG_SEQ};
localparam logic [63:0] IDLE_D = {8{XG_IDLE}};
logic [255:0] t_xd = {4{IDLE_D}};
logic [31:0]  t_xc = '1;
always_ff @(posedge clk) begin
    if (tx_ce) begin
        if (ctl_tx_fault) begin
            t_xd <= {4{LF_D}};   t_xc <= {4{8'hF1}};
        end else if (stat_local_fault) begin
            t_xd <= {4{RF_D}};   t_xc <= {4{8'hF1}};
        end else if (stat_remote_fault) begin
            t_xd <= {4{IDLE_D}}; t_xc <= '1;
        end else begin
            t_xd <= m_xd;        t_xc <= m_xc;
        end
    end
    gt_loopback <= ctl_loopback ? LOOPBACK_MODE : 3'b000;
end

omac_40g_pcs_tx #(.AM_PERIOD(AM_PERIOD), .SCR_INIT(SCR_INIT)) u_pcs_tx (
    .clk(clk), .rst(tx_rst), .ce(tx_ce), .xd(t_xd), .xc(t_xc), .gt_tx_hdr(gt_tx_hdr), .gt_tx_data(gt_tx_data));

// ======================= RX watchdog (clk) =======================
localparam int WDW = $clog2(RX_WATCHDOG + 1);
logic [WDW-1:0] wd_cnt = '0;
logic [6:0]     wd_pulse = '0;
always_ff @(posedge clk) begin
    if (!rx_ready_s || (s_lock && !s_hiber)) begin
        wd_cnt <= '0;
    end else if (wd_cnt == WDW'(RX_WATCHDOG)) begin
        wd_cnt   <= '0;
        wd_pulse <= 7'd64;
    end else begin
        wd_cnt <= wd_cnt + 1'b1;
    end
    if (wd_pulse != '0) wd_pulse <= wd_pulse - 1'b1;
    gt_rx_reset_req <= (wd_pulse != '0);
    if (rst) begin
        wd_cnt   <= '0;
        wd_pulse <= '0;
        gt_rx_reset_req <= 1'b0;
    end
end

endmodule

`resetall
