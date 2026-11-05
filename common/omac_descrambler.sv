// SPDX-License-Identifier: MIT
//
// omac_descrambler - 64-bit parallel descrambler for x^58 + x^39 + 1 (IEEE 802.3
// clause 49.2.6). Feed-forward: the state is the last 58 received bits, so it
// synchronises itself after one block. Registered output, advances with `en`.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_descrambler (
    input  wire logic        clk,
    input  wire logic        en,
    input  wire logic [63:0] din,
    output logic      [63:0] dout
);

logic [57:0]  state = '0;
logic [121:0] r;
assign r = omac_pkg::descramble(state, din);

always_ff @(posedge clk) begin
    if (en) begin
        state <= r[121:64];
        dout  <= r[63:0];
    end
end

endmodule

`resetall
