// SPDX-License-Identifier: MIT
//
// omac_async_fifo - dual-clock FIFO with gray-coded pointers (LUTRAM array,
// asynchronous read), first-word fall-through on the read side. DEPTH is a
// power of two (>= 8). Writes while full are dropped and flagged with
// wr_overflow (one-cycle pulse); wr_free is the number of free entries as the
// write side sees it (conservative: reads show up 2-3 wr_clk cycles late). The
// read side sees a word 3-4 rd_clk cycles
// after it was written. No reset of the array; wr_rst / rd_rst reset the
// pointers of their side and must overlap (both sides reset together).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_async_fifo #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 32
) (
    input  wire logic             wr_clk,
    input  wire logic             wr_rst,
    input  wire logic             wr_en,
    input  wire logic [WIDTH-1:0] wr_data,
    output logic                  wr_overflow,
    output wire logic [$clog2(DEPTH):0] wr_free,

    input  wire logic             rd_clk,
    input  wire logic             rd_rst,
    input  wire logic             rd_en,       // pop (when rd_valid)
    output wire logic [WIDTH-1:0] rd_data,
    output wire logic             rd_valid
);

localparam int AW = $clog2(DEPTH);

function automatic logic [AW:0] bin2gray(input logic [AW:0] b);
    return b ^ (b >> 1);
endfunction

function automatic logic [AW:0] gray2bin(input logic [AW:0] g);
    logic [AW:0] b;
    b[AW] = g[AW];
    for (int i = AW - 1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
endfunction

(* ram_style = "distributed" *) logic [WIDTH-1:0] mem [DEPTH];

logic [AW:0] wr_ptr = '0, wr_gray = '0;
logic [AW:0] rd_ptr = '0, rd_gray = '0;

// ---------------- write side ----------------
(* ASYNC_REG = "TRUE" *) logic [AW:0] wr_rgray0 = '0, wr_rgray1 = '0;
wire  [AW:0] wr_rptr = gray2bin(wr_rgray1);
wire         full = (wr_ptr[AW-1:0] == wr_rptr[AW-1:0]) && (wr_ptr[AW] != wr_rptr[AW]);
assign       wr_free = (AW+1)'(DEPTH) - (wr_ptr - wr_rptr);

always_ff @(posedge wr_clk) begin
    if (wr_en && !full) mem[wr_ptr[AW-1:0]] <= wr_data;
end

always_ff @(posedge wr_clk) begin
    wr_overflow <= wr_en && full;
    if (wr_en && !full) wr_ptr <= wr_ptr + 1'b1;
    wr_gray   <= bin2gray(wr_ptr + (wr_en && !full));
    wr_rgray0 <= rd_gray;
    wr_rgray1 <= wr_rgray0;
    if (wr_rst) begin
        wr_ptr  <= '0;
        wr_gray <= '0;
        wr_overflow <= 1'b0;
    end
end

// ---------------- read side ----------------
(* ASYNC_REG = "TRUE" *) logic [AW:0] rd_wgray0 = '0, rd_wgray1 = '0;
logic [AW:0] rd_wptr = '0;

assign rd_valid = (rd_ptr != rd_wptr);
assign rd_data  = mem[rd_ptr[AW-1:0]];

always_ff @(posedge rd_clk) begin
    rd_wgray0 <= wr_gray;
    rd_wgray1 <= rd_wgray0;
    rd_wptr   <= gray2bin(rd_wgray1);
    if (rd_en && rd_valid) rd_ptr <= rd_ptr + 1'b1;
    rd_gray <= bin2gray(rd_ptr + (rd_en && rd_valid));
    if (rd_rst) begin
        rd_ptr  <= '0;
        rd_gray <= '0;
        rd_wptr <= '0;
    end
end

endmodule

`resetall
