// SPDX-License-Identifier: MIT
//
// omac_10g_mac_tx - 64-bit Ethernet MAC + RS transmit: AXI-Stream frames (no
// FCS) -> XGMII 64-bit columns, one per cycle.
//   arbiter  at frame boundaries: a requested PAUSE frame first, then user
//            frames (while tx_enable and not hold)
//   pad      frames shorter than 60 bytes are padded with zeros (TX_PAD = 1)
//   fcs      CRC-32 appended (one extra beat when the last beat has > 4 bytes);
//            the CRC and the merge are two pipeline stages
//   columns  preamble + SFD with /S/ in lane 0 or lane 4, data, /T/, idles.
//            Inter-packet gap: the gap from /T/ (inclusive) to the next /S/ is
//            at least 9 + dic bytes and the next /S/ sits on a 4-byte boundary;
//            the deficit idle count dic (0..3) keeps the average at 12 bytes
//            (IEEE 802.3 clause 46.3.1.4).
// Once a frame has started on the wire the next beat must be available on
// every cycle; if the user drops tvalid inside a frame, the frame is ended
// with an error column (/E/ in every lane), ev_underflow pulses and the rest
// of the frame is discarded. tuser (abort) on any beat does the same
// (ev_abort).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_mac_tx #(
    parameter bit TX_PAD   = 1'b1,
    parameter bit PAUSE_EN = 1'b1
) (
    input  wire logic        clk,
    input  wire logic        rst,

    input  wire logic [63:0] s_tdata,
    input  wire logic [7:0]  s_tkeep,
    input  wire logic        s_tvalid,
    output wire logic        s_tready,
    input  wire logic        s_tlast,
    input  wire logic        s_tuser,

    input  wire logic        tx_enable,
    input  wire logic        hold,          // received PAUSE in force and honoured

    input  wire logic        pause_req,
    input  wire logic        pause_req_xon,
    output logic             pause_ack,
    input  wire logic [15:0] pause_quanta,
    input  wire logic [47:0] mac_addr,

    output logic [63:0]      xd,
    output logic [7:0]       xc,

    output logic             ev_frame,
    output logic             ev_pause,
    output logic             ev_underflow,
    output logic             ev_abort
);

import omac_pkg::*;

// ---------------- arbiter ----------------
typedef enum logic [1:0] { A_NONE, A_USER, A_PAUSE } asel_t;
asel_t sel = A_NONE;

logic [63:0] pf_tdata;
logic [7:0]  pf_tkeep;
logic        pf_tvalid, pf_tlast, pf_busy;
logic        a_ready;
wire         pf_start = PAUSE_EN && (sel == A_NONE) && pause_req && tx_enable && !pf_busy;

omac_pause_frame #(.DATA_WIDTH(64)) u_pf (
    .clk(clk), .rst(rst), .start(pf_start),
    .pause_time(pause_req_xon ? 16'd0 : pause_quanta), .mac_addr(mac_addr), .busy(pf_busy),
    .m_axis_tdata(pf_tdata), .m_axis_tkeep(pf_tkeep), .m_axis_tvalid(pf_tvalid),
    .m_axis_tready(sel == A_PAUSE && a_ready), .m_axis_tlast(pf_tlast));

wire         a_valid = (sel == A_USER) ? s_tvalid : (sel == A_PAUSE) ? pf_tvalid : 1'b0;
wire  [63:0] a_data  = (sel == A_PAUSE) ? pf_tdata : s_tdata;
wire  [7:0]  a_keep  = (sel == A_PAUSE) ? pf_tkeep : s_tkeep;
wire         a_last  = (sel == A_PAUSE) ? pf_tlast : s_tlast;
wire         a_user  = (sel == A_USER) && s_tuser;
assign s_tready = (sel == A_USER) && a_ready;

always_ff @(posedge clk) begin
    pause_ack <= 1'b0;
    ev_pause  <= 1'b0;
    case (sel)
        A_NONE: begin
            if (pf_start) begin
                sel       <= A_PAUSE;
                pause_ack <= 1'b1;
            end else if (s_tvalid && tx_enable && !hold) begin
                sel <= A_USER;
            end
        end
        A_USER:  if (a_valid && a_ready && a_last) sel <= A_NONE;
        default: if (a_valid && a_ready && a_last) begin
            sel      <= A_NONE;
            ev_pause <= 1'b1;
        end
    endcase
    if (rst) begin
        sel       <= A_NONE;
        pause_ack <= 1'b0;
        ev_pause  <= 1'b0;
    end
end

// ---------------- pad ----------------
logic        p_valid = 1'b0, p_last = 1'b0, p_err = 1'b0;
logic [63:0] p_data;
logic [3:0]  p_n;
logic        p_ready;
logic        pad = 1'b0;
logic [6:0]  pcnt = '0;          // bytes of the frame so far (saturates at 64)

function automatic logic [3:0] keep_n(input logic [7:0] k);
    logic [3:0] n;
    n = 4'd0;
    for (int i = 0; i < 8; i++) if (k[i]) n = 4'(i + 1);
    return n;
endfunction

function automatic logic [63:0] keep_mask(input logic [3:0] n);
    logic [63:0] m;
    for (int i = 0; i < 8; i++) m[8*i +: 8] = (i < n) ? 8'hFF : 8'h00;
    return m;
endfunction

assign a_ready = (!p_valid || p_ready) && !pad;

always_ff @(posedge clk) begin
    logic [3:0] n;
    if (p_valid && p_ready) p_valid <= 1'b0;
    if (pad && (!p_valid || p_ready)) begin
        p_valid <= 1'b1;
        p_data  <= '0;
        p_err   <= 1'b0;
        if (pcnt + 7'd8 >= 7'd60) begin
            p_n    <= 4'(60 - pcnt);
            p_last <= 1'b1;
            pad    <= 1'b0;
            pcnt   <= '0;
        end else begin
            p_n    <= 4'd8;
            p_last <= 1'b0;
            pcnt   <= pcnt + 7'd8;
        end
    end else if (a_valid && a_ready) begin
        n = a_last ? keep_n(a_keep) : 4'd8;
        p_valid <= 1'b1;
        p_data  <= a_data & keep_mask(n);
        p_err   <= a_user;
        if (a_last && TX_PAD && (pcnt + 7'(n) < 7'd60)) begin
            if (pcnt + 7'd8 >= 7'd60) begin
                p_n    <= 4'(60 - pcnt);
                p_last <= 1'b1;
                pcnt   <= '0;
            end else begin
                p_n    <= 4'd8;
                p_last <= 1'b0;
                pad    <= 1'b1;
                pcnt   <= pcnt + 7'd8;
            end
        end else begin
            p_n    <= n;
            p_last <= a_last;
            pcnt   <= a_last ? 7'd0 : ((pcnt >= 7'd64) ? pcnt : pcnt + 7'd8);
        end
    end
    if (rst) begin
        p_valid <= 1'b0;
        pad     <= 1'b0;
        pcnt    <= '0;
    end
end

// ---------------- FCS ----------------
// two stages: Q computes the CRC register after each word (the running state is a
// one-cycle loop), F merges the inverted CRC of a last word into the data (from
// registers, so the merge shifter is not behind the CRC network: 25G timing)
logic        q_valid = 1'b0, q_last = 1'b0, q_err = 1'b0;
logic [63:0] q_data;
logic [3:0]  q_n;
logic [31:0] q_crc;
logic        q_ready;
logic        f_valid = 1'b0, f_last = 1'b0, f_err = 1'b0;
logic [63:0] f_data;
logic [3:0]  f_n;
logic        f_ready;
logic        extra = 1'b0;
logic [31:0] extra_d;
logic [3:0]  extra_n;
logic [31:0] crc = CRC_INIT;
logic        first = 1'b1;
logic [31:0] crc_new;
logic [95:0] fcs_sh;

omac_crc32 #(.BYTES(8)) u_crc (
    .crc_in(first ? CRC_INIT : crc), .data(p_data), .nbytes(p_n), .crc_out(crc_new));
assign p_ready = !q_valid || q_ready;
assign fcs_sh  = {64'd0, ~q_crc} << (8 * q_n);
assign q_ready = (!f_valid || f_ready) && !extra;

always_ff @(posedge clk) begin
    if (q_valid && q_ready) q_valid <= 1'b0;
    if (p_valid && p_ready) begin
        crc     <= crc_new;
        first   <= p_last;
        q_valid <= 1'b1;
        q_data  <= p_data;
        q_n     <= p_n;
        q_last  <= p_last;
        q_err   <= p_err;
        q_crc   <= crc_new;
    end
    if (rst) begin
        q_valid <= 1'b0;
        first   <= 1'b1;
    end
end

always_ff @(posedge clk) begin
    if (f_valid && f_ready) f_valid <= 1'b0;
    if (extra && (!f_valid || f_ready)) begin
        f_valid <= 1'b1;
        f_data  <= {32'd0, extra_d};
        f_n     <= extra_n;
        f_last  <= 1'b1;
        f_err   <= 1'b0;
        extra   <= 1'b0;
    end else if (q_valid && q_ready) begin
        f_valid <= 1'b1;
        f_err   <= q_err;
        if (!q_last) begin
            f_data <= q_data;
            f_n    <= 4'd8;
            f_last <= 1'b0;
        end else if (q_n <= 4'd4) begin
            f_data <= q_data | fcs_sh[63:0];
            f_n    <= q_n + 4'd4;
            f_last <= 1'b1;
        end else begin
            f_data  <= q_data | fcs_sh[63:0];
            f_n     <= 4'd8;
            f_last  <= 1'b0;
            extra   <= 1'b1;
            extra_d <= fcs_sh[95:64];
            extra_n <= q_n - 4'd4;
        end
    end
    if (rst) begin
        f_valid <= 1'b0;
        extra   <= 1'b0;
    end
end

// ---------------- XGMII columns ----------------
typedef enum logic [2:0] { C_IDLE, C_D0, C_D4, C_T0, C_TAIL, C_DRAIN } cst_t;
cst_t        cst = C_IDLE;
logic [6:0]  gap = 7'd64;        // IPG bytes since /T/ (inclusive), saturating
logic [1:0]  dic = '0;
logic [31:0] h;                  // bytes held for the lane-4 alignment
logic [2:0]  hn;

localparam logic [63:0] IDLE_D  = {8{XG_IDLE}};
localparam logic [63:0] ERR_D   = {8{XG_ERROR}};
localparam logic [63:0] S0_D    = {ETH_SFD, {6{ETH_PRE}}, XG_START};
localparam logic [63:0] S4_D    = {{3{ETH_PRE}}, XG_START, {4{XG_IDLE}}};
localparam logic [31:0] S4_H    = {ETH_SFD, {3{ETH_PRE}}};

assign f_ready = (cst == C_D0) || (cst == C_D4) || (cst == C_DRAIN);

// n data bytes of `w` in lanes 0..n-1, /T/ in lane n, idles above (n = 0..7)
function automatic logic [71:0] term_col(input logic [63:0] w, input logic [3:0] n);
    logic [63:0] d;
    logic [7:0]  c;
    for (int i = 0; i < 8; i++) begin
        if (i < n)       begin d[8*i +: 8] = w[8*i +: 8]; c[i] = 1'b0; end
        else if (i == n) begin d[8*i +: 8] = XG_TERM;      c[i] = 1'b1; end
        else             begin d[8*i +: 8] = XG_IDLE;      c[i] = 1'b1; end
    end
    return {c, d};
endfunction

function automatic logic [1:0] dic_next(input logic [1:0] dic_o, input logic [6:0] g);
    int v;
    v = int'(dic_o) + 12 - int'(g);
    if (v < 0) v = 0;
    if (v > 3) v = 3;
    return 2'(v);
endfunction

wire [6:0] gmin = 7'd9 + 7'(dic);

always_ff @(posedge clk) begin
    logic [71:0] tc;
    ev_frame     <= 1'b0;
    ev_underflow <= 1'b0;
    ev_abort     <= 1'b0;
    xd <= IDLE_D;
    xc <= 8'hFF;
    case (cst)
        C_IDLE: begin
            if (f_valid && gap >= gmin) begin
                xd  <= S0_D;
                xc  <= 8'h01;
                dic <= dic_next(dic, gap);
                cst <= C_D0;
            end else if (f_valid && gap + 7'd4 >= gmin) begin
                xd  <= S4_D;
                xc  <= 8'h1F;
                h   <= S4_H;
                dic <= dic_next(dic, gap + 7'd4);
                cst <= C_D4;
            end else begin
                gap <= (gap >= 7'd56) ? 7'd64 : gap + 7'd8;
            end
        end
        C_D0: begin
            if (!f_valid || f_err) begin
                xd  <= ERR_D;
                xc  <= 8'hFF;
                gap <= 7'd8;
                ev_underflow <= !f_valid;
                ev_abort     <= f_valid;
                cst <= (f_valid && f_last) ? C_IDLE : C_DRAIN;
            end else if (!f_last) begin
                xd <= f_data;
                xc <= 8'h00;
            end else if (f_n == 4'd8) begin
                xd  <= f_data;
                xc  <= 8'h00;
                cst <= C_T0;
            end else begin
                tc   = term_col(f_data, f_n);
                xd  <= tc[63:0];
                xc  <= tc[71:64];
                gap <= 7'd8 - 7'(f_n);
                ev_frame <= 1'b1;
                cst <= C_IDLE;
            end
        end
        C_D4: begin
            if (!f_valid || f_err) begin
                xd  <= ERR_D;
                xc  <= 8'hFF;
                gap <= 7'd8;
                ev_underflow <= !f_valid;
                ev_abort     <= f_valid;
                cst <= (f_valid && f_last) ? C_IDLE : C_DRAIN;
            end else if (!f_last || f_n >= 4'd4) begin
                xd <= {f_data[31:0], h};
                xc <= 8'h00;
                h  <= f_data[63:32];
                if (f_last && f_n == 4'd4) cst <= C_T0;
                else if (f_last) begin
                    hn  <= 3'(f_n - 4'd4);
                    cst <= C_TAIL;
                end
            end else begin
                tc   = term_col({f_data[31:0], h}, f_n + 4'd4);
                xd  <= tc[63:0];
                xc  <= tc[71:64];
                gap <= 7'd4 - 7'(f_n);
                ev_frame <= 1'b1;
                cst <= C_IDLE;
            end
        end
        C_T0: begin
            xd  <= {{7{XG_IDLE}}, XG_TERM};
            xc  <= 8'hFF;
            gap <= 7'd8;
            ev_frame <= 1'b1;
            cst <= C_IDLE;
        end
        C_TAIL: begin
            tc   = term_col({32'd0, h}, 4'(hn));
            xd  <= tc[63:0];
            xc  <= tc[71:64];
            gap <= 7'd8 - 7'(hn);
            ev_frame <= 1'b1;
            cst <= C_IDLE;
        end
        default: begin   // C_DRAIN: discard the rest of an aborted frame
            gap <= (gap >= 7'd56) ? 7'd64 : gap + 7'd8;
            if (f_valid && f_last) cst <= C_IDLE;
        end
    endcase
    if (rst) begin
        cst <= C_IDLE;
        gap <= 7'd64;
        dic <= '0;
        ev_frame     <= 1'b0;
        ev_underflow <= 1'b0;
        ev_abort     <= 1'b0;
    end
end

endmodule

`resetall
