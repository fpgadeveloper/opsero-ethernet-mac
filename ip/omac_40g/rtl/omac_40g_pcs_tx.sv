// SPDX-License-Identifier: MIT
//
// omac_40g_pcs_tx - 40GBASE-R PCS transmit (IEEE 802.3 clause 82): four XLGMII
// 8-byte columns per cycle ->
//   encode    64B/66B, clause 82 block subset (omac_40g_pkg::enc66_r4)
//   scramble  one x^58 + x^39 + 1 scrambler over the aggregate stream, column 0
//             first; the sync headers are not scrambled
//   distribute block k of the aggregate stream -> PCS lane k mod 4: with
//             four blocks per cycle, column i of every beat goes to lane i
//   AM        every AM_PERIOD cycles (= blocks per lane) one cycle carries the
//             alignment markers of the four lanes instead of data, with
//             BIP3 over the lane's blocks since the previous AM. During
//             that cycle `ce` is low: the encoder, the scrambler and everything
//             upstream (MAC, user tready) hold for one cycle, so no data is lost
//             and the MAC sends 1/AM_PERIOD fewer beats (clause 82 deletes idles
//             for the same purpose; here the MAC never produces them).
// Output: gt_tx_hdr[2*l +: 2] / gt_tx_data[64*l +: 64] = PCS lane l, IEEE bit
// order, one block per lane per cycle. Latency 3 cycles.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_40g_pcs_tx #(
    parameter int          AM_PERIOD = 16384,
    parameter bit          SCRAMBLE  = 1'b1,     // 0 only for the AM/BIP vector test
    parameter logic [57:0] SCR_INIT  = '1
) (
    input  wire logic         clk,
    input  wire logic         rst,
    output wire logic         ce,
    input  wire logic [255:0] xd,
    input  wire logic [31:0]  xc,
    output logic      [7:0]   gt_tx_hdr,
    output logic      [255:0] gt_tx_data
);

import omac_pkg::*;
import omac_40g_pkg::*;

localparam int AW = $clog2(AM_PERIOD);

// AM slot: the last cycle of every period
logic [AW-1:0] am_cnt = '0;
wire           am_cycle = (am_cnt == AW'(AM_PERIOD - 1));
assign ce = !am_cycle;

always_ff @(posedge clk) begin
    am_cnt <= am_cnt + 1'b1;
    if (rst) am_cnt <= '0;
end

// stage 1: encode
logic [65:0] blk [4];
always_ff @(posedge clk) begin
    if (ce) for (int i = 0; i < 4; i++) blk[i] <= enc66_r4(xd[64*i +: 64], xc[8*i +: 8]);
    if (rst) for (int i = 0; i < 4; i++) blk[i] <= EBLOCK;
end

// stage 2: scramble the four payloads in stream order
logic [57:0] scr = SCR_INIT;
logic [65:0] sblk [4];
always_ff @(posedge clk) begin
    logic [57:0]  st;
    logic [121:0] r;
    if (ce) begin
        st = scr;
        for (int i = 0; i < 4; i++) begin
            r = scramble(st, blk[i][65:2]);
            st = r[121:64];
            sblk[i] <= {SCRAMBLE ? r[63:0] : blk[i][65:2], blk[i][1:0]};
        end
        scr <= st;
    end
    if (rst) begin
        scr <= SCR_INIT;
        for (int i = 0; i < 4; i++) sblk[i] <= EBLOCK;
    end
end

// stage 3: AM insertion, BIP3
logic [7:0] bip [4];
always_ff @(posedge clk) begin
    for (int l = 0; l < 4; l++) begin
        logic [65:0] o;
        if (am_cycle) begin
            o = am_block(2'(l), bip[l]);
            bip[l] <= bip8(o);
        end else begin
            o = sblk[l];
            bip[l] <= bip[l] ^ bip8(o);
        end
        gt_tx_hdr[2*l +: 2]   <= o[1:0];
        gt_tx_data[64*l +: 64] <= o[65:2];
    end
    if (rst) for (int l = 0; l < 4; l++) bip[l] <= '0;
end

endmodule

`resetall
