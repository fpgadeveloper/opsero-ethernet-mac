// SPDX-License-Identifier: MIT
//
// omac_sync_reset - reset synchroniser: asserts asynchronously, releases
// synchronously to clk after STAGES cycles. rst_in is active high.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_sync_reset #(
    parameter int STAGES = 4
) (
    input  wire logic clk,
    input  wire logic rst_in,
    output wire logic rst_out
);

(* ASYNC_REG = "TRUE" *) logic [STAGES-1:0] sync_reg = '1;

always_ff @(posedge clk or posedge rst_in) begin
    if (rst_in) sync_reg <= '1;
    else        sync_reg <= {sync_reg[STAGES-2:0], 1'b0};
end

assign rst_out = sync_reg[STAGES-1];

endmodule

`resetall
