// SPDX-License-Identifier: MIT
//
// omac_scrambler - 64-bit parallel self-synchronising scrambler, polynomial
// x^58 + x^39 + 1 (IEEE 802.3 clause 49.2.6), bit 0 first. Registered output;
// the state advances on every cycle with `en` (one block payload per cycle; the
// sync header is not scrambled). INIT is the state after reset (any value).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_scrambler #(
    parameter logic [57:0] INIT = '1
) (
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic        en,
    input  wire logic [63:0] din,
    output logic      [63:0] dout
);

logic [57:0]  state = INIT;
logic [121:0] r;
assign r = omac_pkg::scramble(state, din);

always_ff @(posedge clk) begin
    if (en) begin
        state <= r[121:64];
        dout  <= r[63:0];
    end
    if (rst) state <= INIT;
end

endmodule

`resetall
