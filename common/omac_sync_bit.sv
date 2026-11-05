// SPDX-License-Identifier: MIT
//
// omac_sync_bit - two-flop (STAGES) synchroniser for level signals into clk.
// Constrain the input paths as asynchronous (set_max_delay -datapath_only or
// clock groups); the flops carry ASYNC_REG.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_sync_bit #(
    parameter int   WIDTH  = 1,
    parameter int   STAGES = 2,
    parameter logic INIT   = 1'b0
) (
    input  wire logic             clk,
    input  wire logic [WIDTH-1:0] din,
    output wire logic [WIDTH-1:0] dout
);

(* ASYNC_REG = "TRUE" *) logic [WIDTH-1:0] sync_reg [STAGES] = '{default: {WIDTH{INIT}}};

always_ff @(posedge clk) begin
    sync_reg[0] <= din;
    for (int i = 1; i < STAGES; i++) sync_reg[i] <= sync_reg[i-1];
end

assign dout = sync_reg[STAGES-1];

endmodule

`resetall
