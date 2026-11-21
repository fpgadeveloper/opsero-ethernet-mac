// SPDX-License-Identifier: MIT
//
// omac_10g_usx_rx - USXGMII receive rate adaptation (omac_10g, USXGMII_EN = 1),
// in the recovered clock, between the PCS (omac_10g_pcs_rx) and the MAC
// (omac_10g_mac_rx): of the 32-bit words of the decoded XGMII stream it keeps
// one in `rep_n` (the sample) and rebuilds 64-bit columns for the MAC.
//   * Sampling phase: every word that carries /S/ in its lane 0 is a sample and
//     restarts the count (EDCS-1517762 2.6.2 / 2.6.4: "receive logic samples the
//     1st 4-byte word containing SOP", then every rep_n-th word). The phase is
//     therefore found again at every frame: idles that the PHY inserts or
//     deletes between frames for clock compensation (in units of 4 bytes, so
//     /S/ may arrive in lane 0 or lane 4 of a block) move only the idle part.
//     Between frames the count runs on; a sample that falls in the lane-0 word
//     of a column whose lane-4 word carries /S/ is dropped (it is an idle).
//   * Columns to the MAC: samples are paired into columns in arrival order; a
//     /S/ sample keeps the lane it had on the transceiver interface (lane 4
//     with an idle word below it when nothing is pending; lane 0 by first
//     emitting the pending word with an idle word above it), so the MAC's
//     start-lane and timestamp logic see the original block position. ots is
//     the xts of the column that carried the /S/ word (for the column holding
//     the /S/ sample), otherwise of the column that completed the output.
//   * Replica check: inside a frame (from the /S/ sample to the copies of the
//     word with /T/) every non-sampled word must be the expected copy of its
//     sample: the copies of the /S/ word data in lane 0 (any value) and the
//     preamble in lanes 1-3, the copies of the /T/ word idle words, all other
//     copies identical. A mismatch pulses ev_rep_err; with `strict` = 1 the next
//     sample of the frame is replaced by an error word (/E/ in all four lanes),
//     so the MAC ends the frame as bad. Outside frames nothing is checked (idle
//     insertion / deletion).
// rep_n = 1: the columns pass through unchanged (one register). Latency 1
// cycle (plus the pairing of two samples into one column at rep_n >= 2).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_usx_rx #(
    parameter int TS_W = 1
) (
    input  wire logic            clk,
    input  wire logic            rst,
    input  wire logic [9:0]      rep_n,
    input  wire logic            strict,

    input  wire logic            xvalid,
    input  wire logic [63:0]     xd,
    input  wire logic [7:0]      xc,
    input  wire logic [TS_W-1:0] xts,

    output logic                 ovalid = 1'b0,
    output logic      [63:0]     od,
    output logic      [7:0]      oc,
    output logic      [TS_W-1:0] ots,
    output logic                 ev_rep_err = 1'b0
);

import omac_pkg::*;

localparam logic [31:0] IDLE_W = {4{XG_IDLE}};
localparam logic [31:0] ERR_W  = {4{XG_ERROR}};

logic [9:0]  n = 10'd1, k = '0;
logic        chk = 1'b0;          // the copies of the current sample are checked
logic        infr = 1'b0;         // inside a frame (between the /S/ and the /T/ sample)
logic [1:0]  kind = '0;           // the current sample: 0 other, 1 /S/, 2 /T/
logic [31:0] rw = '0;             // the current sample
logic [3:0]  rc = '0;
logic        poison = 1'b0;
logic        pend = 1'b0;         // a sample waits for its partner (it goes to lanes 0-3)
logic [31:0] pw = '0;
logic [3:0]  pc = '0;
logic [TS_W-1:0] pts = '0;

function automatic logic is_s(input logic [31:0] w, input logic [3:0] c);
    return c[0] && w[7:0] == XG_START;
endfunction

function automatic logic has_t(input logic [31:0] w, input logic [3:0] c);
    logic t;
    t = 1'b0;
    for (int i = 0; i < 4; i++) if (c[i] && w[8*i +: 8] == XG_TERM) t = 1'b1;
    return t;
endfunction

always_ff @(posedge clk) begin
    logic [9:0]  kk;
    logic        ch, inf, pd, poi, err, emit, samp, s, ok;
    logic [1:0]  kd;
    logic [31:0] w, sw, rwv, pwv;
    logic [3:0]  c, sc, rcv, pcv;
    logic [TS_W-1:0] ptsv;
    logic [63:0] ed;
    logic [7:0]  ec;
    logic [TS_W-1:0] ets;
    n <= (rep_n == '0) ? 10'd1 : rep_n;
    ovalid     <= 1'b0;
    ev_rep_err <= 1'b0;
    if (n == 10'd1) begin
        ovalid <= xvalid;
        od     <= xd;
        oc     <= xc;
        ots    <= xts;
        k      <= '0;
        pend   <= 1'b0;
        chk    <= 1'b0;
        infr   <= 1'b0;
        poison <= 1'b0;
    end else if (xvalid) begin
        kk = k; ch = chk; inf = infr; kd = kind; rwv = rw; rcv = rc; poi = poison;
        pd = pend; pwv = pw; pcv = pc; ptsv = pts;
        err = 1'b0; emit = 1'b0; ed = '0; ec = '0; ets = xts;
        for (int h = 0; h < 2; h++) begin
            w = xd[32*h +: 32];
            c = xc[4*h +: 4];
            s = is_s(w, c);
            samp = s || (kk == '0);
            // a sample in lane 0 under a /S/ in lane 4 of the same column is an idle: drop it
            if (h == 0 && !s && is_s(xd[63:32], xc[7:4])) samp = 1'b0;
            if (samp) begin
                sw = w; sc = c;
                if (s) begin
                    inf = 1'b1;
                    poi = 1'b0;
                    kd  = 2'd1;
                end else if (has_t(w, c)) begin
                    kd  = 2'd2;
                    if (inf && poi) begin sw = ERR_W; sc = 4'hF; end
                    inf = 1'b0;
                    poi = 1'b0;
                end else begin
                    kd  = 2'd0;
                    if (inf && poi) begin sw = ERR_W; sc = 4'hF; poi = 1'b0; end
                end
                ch  = inf || (kd == 2'd2);
                rwv = w; rcv = c;
                kk  = (n == 10'd1) ? 10'd0 : 10'd1;
                // into the column builder
                if (s && h == 1) begin
                    ed = {sw, pd ? pwv : IDLE_W};
                    ec = {sc, pd ? pcv : 4'hF};
                    ets = xts;
                    emit = 1'b1;
                    pd = 1'b0;
                end else if (s && pd) begin
                    ed = {IDLE_W, pwv};
                    ec = {4'hF, pcv};
                    ets = ptsv;
                    emit = 1'b1;
                    pwv = sw; pcv = sc; ptsv = xts;
                end else if (pd) begin
                    ed = {sw, pwv};
                    ec = {sc, pcv};
                    ets = ptsv;
                    emit = 1'b1;
                    pd = 1'b0;
                end else begin
                    pd = 1'b1;
                    pwv = sw; pcv = sc; ptsv = xts;
                end
            end else begin
                case (kd)
                    2'd1:    ok = (c == {rcv[3:1], 1'b0}) && (w[31:8] == rwv[31:8]);
                    2'd2:    ok = (c == 4'hF) && (w == IDLE_W);
                    default: ok = (c == rcv) && (w == rwv);
                endcase
                if (ch && !ok) begin
                    err = 1'b1;
                    if (strict && inf) poi = 1'b1;
                end
                kk = (kk >= n - 10'd1) ? 10'd0 : kk + 10'd1;
            end
        end
        k <= kk; chk <= ch; infr <= inf; kind <= kd; rw <= rwv; rc <= rcv; poison <= poi;
        pend <= pd; pw <= pwv; pc <= pcv; pts <= ptsv;
        ev_rep_err <= err;
        ovalid <= emit;
        if (emit) begin
            od  <= ed;
            oc  <= ec;
            ots <= ets;
        end
    end
    if (rst) begin
        ovalid     <= 1'b0;
        ev_rep_err <= 1'b0;
        k      <= '0;
        pend   <= 1'b0;
        chk    <= 1'b0;
        infr   <= 1'b0;
        poison <= 1'b0;
    end
end

endmodule

`resetall
