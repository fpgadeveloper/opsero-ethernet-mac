// SPDX-License-Identifier: MIT
//
// omac_10g - 10GBASE-R (and 25GBASE-R) Ethernet MAC + PCS, one lane, 64-bit
// AXI-Stream on one user clock. Implements the omac boundary contract
// (docs/interface.md): user side in `clk` (= the transceiver TX user clock),
// GT side = 66-bit blocks to a transceiver in 64B/66B asynchronous gearbox mode
// (gt/omac_gt_usp_gth for UltraScale+ GTH).
//
//   clk domain          gt_rx_clk domain (recovered)
//   AXIS TX -> mac_tx -> RS (faults) -> pcs_tx -> gt_tx_*
//   AXIS RX <- async FIFO <- mac_rx <- RS fault detect <- pcs_rx <- gt_rx_*
//   PAUSE timers, watchdog, status / event crossing in clk
//
// SPEED 10: clk 156.25 MHz (10.3125 Gb/s lane); SPEED 25: same logic, clk
// 390.625 MHz (25.78125 Gb/s, GTY only), BER window 2 ms / 97 by default.
//
// Timestamp hooks (TS_EN = 1; docs/omac_10g.md "Timestamp hooks"): the
// reference plane is the 64B/66B block boundary at the transceiver interface.
//   TX: tx_ts_valid pulses (in clk) one cycle after the /S/ block of a frame
//       was on gt_tx_data/gt_tx_hdr, with tx_ts_val = tx_ts_in of that cycle,
//       tx_ts_lane4 (/S/ in lane 4: the frame starts 32 bits later in the
//       block) and tx_ts_user (0 = a PAUSE frame of the MAC). One pulse per
//       frame, in transmit order.
//   RX: rx_ts_in (gt_rx_clk) is sampled with the block that carries a frame's
//       /S/ as it arrives on gt_rx_data and travels with the frame through
//       the clock crossing: m_axis_rx_ts / m_axis_rx_ts_lane4 are constant on
//       every beat of the delivered frame. Frames that are not delivered never
//       show a timestamp.
// TS_EN = 0 (default): the outputs are 0 and no logic is added.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g #(
    parameter int          DATA_WIDTH     = 64,
    parameter int          SPEED          = 10,
    parameter int          MIN_FRAME      = 64,
    parameter int          MAX_FRAME      = 9600,
    parameter bit          PAUSE_EN       = 1'b1,
    parameter bit          TX_PAD         = 1'b1,      // 0 only for tests (runts)
    parameter int          SLIP_WAIT      = 256,
    parameter int          BER_TIMER_CLKS = (SPEED == 25) ? 781250 : 19532,
    parameter int          BER_THRESH     = (SPEED == 25) ? 97 : 16,
    parameter int          RX_WATCHDOG    = 2097152,   // clk cycles without lock before gt_rx_reset_req
    parameter int          RX_FIFO_DEPTH  = 32,
    parameter logic [2:0]  LOOPBACK_MODE  = 3'b010,    // GT near-end PMA loopback
    parameter logic [57:0] SCR_INIT       = '1,
    parameter bit          TS_EN          = 1'b0,      // timestamp hooks
    parameter int          TS_W           = 32         // width of the time values (TS_EN = 1)
) (
    input  wire logic        clk,
    input  wire logic        rst,

    // transmit AXI-Stream (frames without FCS)
    input  wire logic [63:0] s_axis_tx_tdata,
    input  wire logic [7:0]  s_axis_tx_tkeep,
    input  wire logic        s_axis_tx_tvalid,
    output wire logic        s_axis_tx_tready,
    input  wire logic        s_axis_tx_tlast,
    input  wire logic [0:0]  s_axis_tx_tuser,

    // receive AXI-Stream (FCS stripped, no tready)
    output logic      [63:0] m_axis_rx_tdata,
    output logic      [7:0]  m_axis_rx_tkeep,
    output logic             m_axis_rx_tvalid,
    output logic             m_axis_rx_tlast,
    output logic      [0:0]  m_axis_rx_tuser,

    // control
    input  wire logic        ctl_tx_enable,
    input  wire logic        ctl_rx_enable,
    input  wire logic        ctl_loopback,
    input  wire logic        ctl_tx_fault,
    input  wire logic        ctl_pause_tx_honour,
    input  wire logic        ctl_tx_pause_send,
    input  wire logic [15:0] ctl_tx_pause_quanta,
    input  wire logic [15:0] ctl_tx_pause_refresh,
    input  wire logic [47:0] ctl_mac_addr,

    // status
    output logic             stat_link_up,
    output wire logic        stat_block_lock,
    output wire logic        stat_hi_ber,
    output wire logic        stat_local_fault,
    output wire logic        stat_remote_fault,
    output wire logic        stat_rx_pause_req,
    output logic      [15:0] stat_rx_pause_quanta,
    output wire logic        stat_tx_pause_active,

    // events
    output wire logic        ev_tx_frame,
    output wire logic        ev_tx_pause,
    output wire logic        ev_tx_underflow,
    output wire logic        ev_tx_abort,
    output wire logic        ev_rx_frame_good,
    output wire logic        ev_rx_frame_bad,
    output wire logic        ev_rx_fcs_error,
    output wire logic        ev_rx_runt,
    output wire logic        ev_rx_oversize,
    output wire logic        ev_rx_pause,
    output wire logic        ev_rx_bad_block,
    output wire logic        ev_rx_sequence_error,

    // GT transmit (clk)
    input  wire logic        gt_tx_ready,
    output wire logic [1:0]  gt_tx_hdr,
    output wire logic [63:0] gt_tx_data,
    output logic      [2:0]  gt_loopback,

    // GT receive
    input  wire logic        gt_rx_clk,
    input  wire logic        gt_rx_ready,
    input  wire logic        gt_rx_valid,
    input  wire logic [1:0]  gt_rx_hdr,
    input  wire logic [63:0] gt_rx_data,
    output wire logic        gt_rx_slip,
    output logic             gt_rx_reset_req,

    // timestamp hooks (TS_EN = 1; outputs 0 otherwise)
    input  wire logic [TS_W-1:0] tx_ts_in,         // clk: the time to latch at a frame's /S/
    output logic             tx_ts_valid,
    output logic      [TS_W-1:0] tx_ts_val,
    output logic             tx_ts_lane4,
    output logic             tx_ts_user,
    input  wire logic [TS_W-1:0] rx_ts_in,         // gt_rx_clk: the same time in the receive clock
    output logic      [TS_W-1:0] m_axis_rx_ts,     // clk: with every beat of m_axis_rx
    output logic             m_axis_rx_ts_lane4
);

import omac_pkg::*;

initial begin
    if (DATA_WIDTH != 64) $fatal(1, "omac_10g: DATA_WIDTH must be 64");
    if (SPEED != 10 && SPEED != 25) $fatal(1, "omac_10g: SPEED must be 10 or 25");
    if (TS_EN && TS_W < 1) $fatal(1, "omac_10g: TS_W must be >= 1");
end

// timestamp width inside (1 constant-0 bit when the hooks are off)
localparam int TSI = TS_EN ? TS_W : 1;
localparam int TSX = TS_EN ? TS_W + 1 : 0;     // extra RX FIFO bits: {lane4, ts}
wire [TSI-1:0] rx_ts_i = TS_EN ? TSI'(rx_ts_in) : '0;

// ======================= resets =======================
logic tx_ready_s, rx_ready_s;
omac_sync_bit #(.WIDTH(2)) u_sync_rdy (.clk(clk), .din({gt_tx_ready, gt_rx_ready}),
                                       .dout({tx_ready_s, rx_ready_s}));
logic tx_rst = 1'b1;
always_ff @(posedge clk) tx_rst <= rst || !tx_ready_s;

// the RX side (and the write side of the RX FIFO) is reset whenever either
// direction of the transceiver is not ready, so both FIFO sides reset together
logic rx_rst;
omac_sync_reset u_rx_rst (.clk(gt_rx_clk), .rst_in(rst || !gt_rx_ready || !gt_tx_ready), .rst_out(rx_rst));
logic fifo_rd_rst = 1'b1;
always_ff @(posedge clk) fifo_rd_rst <= rst || !rx_ready_s || !tx_ready_s;

// ======================= receive (gt_rx_clk) =======================
logic        r_block_lock, r_hi_ber;
logic        r_xv;
logic [63:0] r_xd;
logic [7:0]  r_xc;
logic        r_bad_block, r_seq_err;
logic [TSI-1:0] r_xts;

omac_10g_pcs_rx #(.SLIP_WAIT(SLIP_WAIT), .BER_TIMER_CLKS(BER_TIMER_CLKS), .BER_THRESH(BER_THRESH),
                  .TS_W(TSI)) u_pcs_rx (
    .clk(gt_rx_clk), .rst(rx_rst), .valid(gt_rx_valid), .hdr(gt_rx_hdr), .data(gt_rx_data),
    .ts_in(rx_ts_i),
    .slip(gt_rx_slip), .block_lock(r_block_lock), .hi_ber(r_hi_ber),
    .xvalid(r_xv), .xd(r_xd), .xc(r_xc), .xts(r_xts), .ev_bad_block(r_bad_block), .ev_seq_error(r_seq_err));

logic [1:0] r_link_fault;
omac_rs_fault #(.COLS(2)) u_rs_fault (
    .clk(gt_rx_clk), .rst(rx_rst), .valid(r_xv), .d(r_xd), .c(r_xc), .link_fault(r_link_fault));

logic rx_enable_r;
omac_sync_bit u_sync_rxen (.clk(gt_rx_clk), .din(ctl_rx_enable), .dout(rx_enable_r));

logic        r_tvalid, r_tlast, r_tuser;
logic [63:0] r_tdata;
logic [7:0]  r_tkeep;
logic        r_pause_ev;
logic [15:0] r_pause_time;
logic        r_ev_good, r_ev_bad, r_ev_fcs, r_ev_runt, r_ev_over;
logic [TSI-1:0] r_ts;
logic        r_ts_l4;

omac_10g_mac_rx #(.MIN_FRAME(MIN_FRAME), .MAX_FRAME(MAX_FRAME), .TS_W(TSI)) u_mac_rx (
    .clk(gt_rx_clk), .rst(rx_rst), .xvalid(r_xv), .xd(r_xd), .xc(r_xc), .xts(r_xts),
    .rx_enable(rx_enable_r), .mac_addr(ctl_mac_addr),
    .m_tvalid(r_tvalid), .m_tdata(r_tdata), .m_tkeep(r_tkeep), .m_tlast(r_tlast), .m_tuser(r_tuser),
    .m_ts(r_ts), .m_ts_lane4(r_ts_l4),
    .pause_ev(r_pause_ev), .pause_time(r_pause_time),
    .ev_good(r_ev_good), .ev_bad(r_ev_bad), .ev_fcs_error(r_ev_fcs), .ev_runt(r_ev_runt),
    .ev_oversize(r_ev_over));

// frames into clk (with TS_EN: the frame's {lane4, ts} on every beat)
localparam int FW = 74 + TSX;
logic [FW-1:0] f_rd, f_wr;
logic          f_valid;
if (TS_EN) begin : g_fifo_ts
    assign f_wr = {r_ts_l4, r_ts[TSI-1:0], r_tuser, r_tlast, r_tkeep, r_tdata};
end else begin : g_fifo
    assign f_wr = {r_tuser, r_tlast, r_tkeep, r_tdata};
end
omac_async_fifo #(.WIDTH(FW), .DEPTH(RX_FIFO_DEPTH)) u_rx_fifo (
    .wr_clk(gt_rx_clk), .wr_rst(rx_rst), .wr_en(r_tvalid),
    .wr_data(f_wr), .wr_overflow(), .wr_free(),
    .rd_clk(clk), .rd_rst(fifo_rd_rst), .rd_en(1'b1), .rd_data(f_rd), .rd_valid(f_valid));

always_ff @(posedge clk) begin
    m_axis_rx_tvalid <= f_valid;
    m_axis_rx_tdata  <= f_rd[63:0];
    m_axis_rx_tkeep  <= f_rd[71:64];
    m_axis_rx_tlast  <= f_rd[72];
    m_axis_rx_tuser  <= f_rd[73];
end
if (TS_EN) begin : g_rx_ts
    always_ff @(posedge clk) begin
        m_axis_rx_ts       <= f_rd[74 +: TS_W];
        m_axis_rx_ts_lane4 <= f_rd[74 + TS_W];
    end
end else begin : g_rx_ts_off
    assign m_axis_rx_ts       = '0;
    assign m_axis_rx_ts_lane4 = 1'b0;
end

// events into clk
omac_cdc_event #(.N(8)) u_cdc_ev (
    .s_clk(gt_rx_clk),
    .s_ev({r_seq_err, r_bad_block, r_pause_ev, r_ev_over, r_ev_runt, r_ev_fcs, r_ev_bad, r_ev_good}),
    .m_clk(clk), .m_rst(tx_rst),
    .m_ev({ev_rx_sequence_error, ev_rx_bad_block, ev_rx_pause, ev_rx_oversize, ev_rx_runt,
           ev_rx_fcs_error, ev_rx_frame_bad, ev_rx_frame_good}));

// status levels into clk
logic s_lock, s_hiber;
logic [1:0] s_fault;
omac_sync_bit #(.WIDTH(4)) u_sync_stat (.clk(clk),
    .din({r_link_fault, r_hi_ber, r_block_lock}), .dout({s_fault, s_hiber, s_lock}));
assign stat_block_lock   = s_lock && rx_ready_s;
assign stat_hi_ber       = s_hiber;
assign stat_local_fault  = (s_fault == 2'd1) || !rx_ready_s;
assign stat_remote_fault = (s_fault == 2'd2);

always_ff @(posedge clk) begin
    stat_link_up <= stat_block_lock && !stat_hi_ber && !stat_local_fault && !stat_remote_fault &&
                    tx_ready_s;
end

// received PAUSE (rx clock -> clk): toggle + quanta held stable (PAUSE frames
// are at least 84 bytes apart, the crossing takes 3 cycles)
logic        r_ptog = 1'b0;
logic [15:0] r_pq = '0;
always_ff @(posedge gt_rx_clk) begin
    if (r_pause_ev) begin
        r_ptog <= !r_ptog;
        r_pq   <= r_pause_time;
    end
end
logic p_tog_s, p_tog_d = 1'b0;
omac_sync_bit u_sync_ptog (.clk(clk), .din(r_ptog), .dout(p_tog_s));
logic        p_load = 1'b0;
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
omac_pause #(.BIT_TIMES_PER_CLK(64)) u_pause (
    .clk(clk), .rst(tx_rst),
    .rx_load(p_load), .rx_quanta(stat_rx_pause_quanta), .rx_pause_req(stat_rx_pause_req),
    .tx_send(PAUSE_EN && ctl_tx_pause_send), .tx_refresh(ctl_tx_pause_refresh),
    .tx_req(pq_req), .tx_req_xon(pq_xon), .tx_ack(pq_ack), .tx_xoff_active(stat_tx_pause_active));

// ======================= transmit (clk) =======================
logic [63:0] m_xd;
logic [7:0]  m_xc;
logic        m_sof, m_sof_l4, m_sof_usr;
omac_10g_mac_tx #(.TX_PAD(TX_PAD), .PAUSE_EN(PAUSE_EN)) u_mac_tx (
    .clk(clk), .rst(tx_rst),
    .s_tdata(s_axis_tx_tdata), .s_tkeep(s_axis_tx_tkeep), .s_tvalid(s_axis_tx_tvalid),
    .s_tready(s_axis_tx_tready), .s_tlast(s_axis_tx_tlast), .s_tuser(s_axis_tx_tuser[0]),
    .tx_enable(ctl_tx_enable), .hold(ctl_pause_tx_honour && stat_rx_pause_req),
    .pause_req(pq_req), .pause_req_xon(pq_xon), .pause_ack(pq_ack),
    .pause_quanta(ctl_tx_pause_quanta), .mac_addr(ctl_mac_addr),
    .xd(m_xd), .xc(m_xc), .sof(m_sof), .sof_lane4(m_sof_l4), .sof_user(m_sof_usr),
    .ev_frame(ev_tx_frame), .ev_pause(ev_tx_pause), .ev_underflow(ev_tx_underflow), .ev_abort(ev_tx_abort));

// RS transmit: link fault signalling (clause 46.3.4.2)
localparam logic [63:0] LF_D   = {LF_CODE, 16'h0000, XG_SEQ, LF_CODE, 16'h0000, XG_SEQ};
localparam logic [63:0] RF_D   = {RF_CODE, 16'h0000, XG_SEQ, RF_CODE, 16'h0000, XG_SEQ};
localparam logic [63:0] IDLE_D = {8{XG_IDLE}};
logic [63:0] t_xd = IDLE_D;
logic [7:0]  t_xc = 8'hFF;
always_ff @(posedge clk) begin
    if (ctl_tx_fault) begin
        t_xd <= LF_D;   t_xc <= 8'h11;
    end else if (stat_local_fault) begin
        t_xd <= RF_D;   t_xc <= 8'h11;
    end else if (stat_remote_fault) begin
        t_xd <= IDLE_D; t_xc <= 8'hFF;
    end else begin
        t_xd <= m_xd;   t_xc <= m_xc;
    end
    gt_loopback <= ctl_loopback ? LOOPBACK_MODE : 3'b000;
end

omac_10g_pcs_tx #(.SCR_INIT(SCR_INIT)) u_pcs_tx (
    .clk(clk), .rst(tx_rst), .xd(t_xd), .xc(t_xc), .gt_tx_hdr(gt_tx_hdr), .gt_tx_data(gt_tx_data));

// TX timestamp: the /S/ column leaves mac_tx on m_xd, then the RS register
// (t_xd), the encoder register (blk) and the scrambler register (gt_tx_data):
// sof delayed by three cycles is high while the /S/ block is on gt_tx_data.
// The pulse also comes while the RS replaces frames by fault columns or idles
// (the frame is then discarded), so the user's per-frame bookkeeping never
// slips.
if (TS_EN) begin : g_tx_ts
    logic [2:0] sof_d = '0, l4_d = '0, usr_d = '0;
    always_ff @(posedge clk) begin
        sof_d <= {sof_d[1:0], m_sof};
        l4_d  <= {l4_d[1:0], m_sof_l4};
        usr_d <= {usr_d[1:0], m_sof_usr};
        tx_ts_valid <= sof_d[2];
        if (sof_d[2]) begin
            tx_ts_val   <= tx_ts_in;
            tx_ts_lane4 <= l4_d[2];
            tx_ts_user  <= usr_d[2];
        end
        if (tx_rst) begin
            sof_d       <= '0;
            tx_ts_valid <= 1'b0;
        end
    end
end else begin : g_tx_ts_off
    assign tx_ts_valid = 1'b0;
    assign tx_ts_val   = '0;
    assign tx_ts_lane4 = 1'b0;
    assign tx_ts_user  = 1'b0;
end

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
