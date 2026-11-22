// SPDX-License-Identifier: MIT
//
// omac_10g_usx_tx - USXGMII transmit rate adaptation (omac_10g, USXGMII_EN = 1):
// one XGMII 64-bit column of the MAC is sent as `rep_n` columns, every 32-bit
// word replicated rep_n times (10G: 1, 5G: 2, 2.5G: 4, 1G: 10, 100M: 100,
// 10M: 1000), so the lane keeps 10.3125 Gb/s at every speed.
//   * Clock enable: `ce` is high in one cycle of every rep_n (always at
//     rep_n = 1) and clocks omac_10g_mac_tx, which then produces one column per
//     rep_n cycles and accepts AXI-Stream beats at that rate. The MAC logic is
//     unchanged; only its register updates are enabled.
//   * Replication: the low word of the held column occupies the first rep_n/2
//     output columns (in both halves), the high word the last rep_n/2. The
//     first copy of each word is the word itself; the other copies follow the
//     Cisco USXGMII single-port specification (EDCS-1150953) section 2.6.1 (the
//     /S/ word and the /T/ word are sent once), so the 64B/66B encoder never
//     sees two /S/ or two /T/ in one column:
//       - a word with /S/ in its lane 0: the copies carry SOP_FILL (a data byte)
//         in lane 0, the preamble bytes in lanes 1-3;
//       - a word with /T/ in any lane: the copies are idle words;
//       - any other word (data, idle, ordered set, error): identical copies.
//     At rep_n >= 2 every frame therefore starts with /S/ in lane 0 of a block
//     (block type 0x78) and ends with a /T/ block followed by idle blocks.
//   * osof: the first copy of a frame's /S/ is in the column on od/oc (aligned
//     with od); osof_l4 = that /S/ is in lane 4 (only possible at rep_n = 1);
//     osof_user = the MAC's sof_user of that frame.
// rep_n must be one of 1, 2, 4, 10, 100, 1000 (the even values and 1 are what
// the logic supports; a change takes effect at once and may cut the column in
// progress: omac_10g changes it only while the transmit path is replaced by
// auto-negotiation). Latency: one register (od is one cycle after xd).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_usx_tx #(
    parameter logic [7:0] SOP_FILL = 8'hAA
) (
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic [9:0]  rep_n,

    output logic             ce = 1'b1,

    input  wire logic [63:0] xd,
    input  wire logic [7:0]  xc,
    input  wire logic        sof,
    input  wire logic        sof_l4,
    input  wire logic        sof_user,

    output logic      [63:0] od = {8{omac_pkg::XG_IDLE}},
    output logic      [7:0]  oc = 8'hFF,
    output logic             osof = 1'b0,
    output logic             osof_l4 = 1'b0,
    output logic             osof_user = 1'b0
);

import omac_pkg::*;

logic [9:0] n = 10'd1, half = 10'd0, ph = '0;

// the copy of a word that follows its first copy: {c[3:0], d[31:0]}
function automatic logic [35:0] rep_word(input logic [31:0] w, input logic [3:0] c);
    logic t;
    t = 1'b0;
    for (int i = 0; i < 4; i++) if (c[i] && w[8*i +: 8] == XG_TERM) t = 1'b1;
    if (c[0] && w[7:0] == XG_START) return {c[3:1], 1'b0, w[31:8], SOP_FILL};
    if (t)                          return {4'hF, {4{XG_IDLE}}};
    return {c, w};
endfunction

always_ff @(posedge clk) begin
    logic [9:0]  phn;
    logic        hi, first;
    logic [31:0] w;
    logic [3:0]  wc;
    logic [35:0] r;
    n    <= (rep_n == '0) ? 10'd1 : rep_n;
    half <= rep_n >> 1;
    // phase of the held column; ce in its last cycle
    phn = ce ? 10'd0 : ph + 10'd1;
    if (phn >= n) phn = '0;
    ph <= phn;
    ce <= (phn == n - 10'd1);
    // output column
    if (n == 10'd1) begin
        od      <= xd;
        oc      <= xc;
        osof    <= sof;
        osof_l4 <= sof_l4;
    end else begin
        hi    = (ph >= half);
        first = (ph == '0) || (ph == half);
        w     = hi ? xd[63:32] : xd[31:0];
        wc    = hi ? xc[7:4]   : xc[3:0];
        r     = rep_word(w, wc);
        od      <= {r[31:0], first ? w : r[31:0]};
        oc      <= {r[35:32], first ? wc : r[35:32]};
        osof    <= first && wc[0] && w[7:0] == XG_START;
        osof_l4 <= 1'b0;
    end
    osof_user <= sof_user;
    if (rst) begin
        ph   <= '0;
        ce   <= 1'b1;
        osof <= 1'b0;
    end
end

endmodule

`resetall
