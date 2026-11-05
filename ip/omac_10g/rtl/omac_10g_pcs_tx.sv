// SPDX-License-Identifier: MIT
//
// omac_10g_pcs_tx - 10GBASE-R / 25GBASE-R PCS transmit (IEEE 802.3 clause 49):
// one XGMII 64-bit column per cycle -> 64B/66B encoder (omac_pkg::enc66,
// invalid columns become the error block) -> scrambler (payload only) ->
// 66-bit block to the transceiver gearbox, IEEE bit order. Latency 2 cycles.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_pcs_tx #(
    parameter logic [57:0] SCR_INIT = '1
) (
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic [63:0] xd,
    input  wire logic [7:0]  xc,
    output logic      [1:0]  gt_tx_hdr,
    output wire logic [63:0] gt_tx_data
);

logic [65:0] blk = omac_pkg::EBLOCK;

always_ff @(posedge clk) begin
    blk       <= omac_pkg::enc66(xd, xc);
    gt_tx_hdr <= blk[1:0];
end

omac_scrambler #(.INIT(SCR_INIT)) u_scr (
    .clk(clk), .rst(rst), .en(1'b1), .din(blk[65:2]), .dout(gt_tx_data));

endmodule

`resetall
