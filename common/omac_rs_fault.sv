// SPDX-License-Identifier: MIT
//
// omac_rs_fault - Reconciliation Sublayer link fault detection (IEEE 802.3
// clause 46.3.4, figure 46-11) on an XGMII-style stream of COLS 4-byte columns
// per cycle (2 for a 64-bit datapath; omac_40g uses 4 columns of 64 bits per
// clause 81, see its COLS parameter). A column is a fault
// sequence when lane 0 is the control character /Q/ (0x9C) and lanes 1-3 are
// the data bytes 0x00 0x00 <code> (0x01 local fault, 0x02 remote fault).
// Four sequences of the same type, each less than 128 columns after the
// previous one, set link_fault to that type; 128 columns without a fault
// sequence clear it. Columns are processed in order within a cycle.
// link_fault: 0 = OK, 1 = Local Fault, 2 = Remote Fault.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_rs_fault #(
    parameter int COLS = 2
) (
    input  wire logic              clk,
    input  wire logic              rst,
    input  wire logic              valid,
    input  wire logic [32*COLS-1:0] d,
    input  wire logic [4*COLS-1:0]  c,
    output logic [1:0]             link_fault
);

logic [1:0] seq_type = 2'd0;    // type of the sequences being counted
logic [2:0] seq_cnt  = '0;      // 0..4
logic [7:0] col_cnt  = '0;      // columns since the last fault sequence

always_ff @(posedge clk) begin
    logic [1:0] lf, st, t;
    logic [2:0] sc;
    logic [7:0] cc;
    lf = link_fault; st = seq_type; sc = seq_cnt; cc = col_cnt;
    if (valid) begin
        for (int k = 0; k < COLS; k++) begin
            t = 2'd0;
            if (c[4*k +: 4] == 4'b0001 && d[32*k +: 8] == omac_pkg::XG_SEQ &&
                d[32*k + 8 +: 16] == 16'h0000) begin
                if (d[32*k + 24 +: 8] == omac_pkg::LF_CODE) t = 2'd1;
                if (d[32*k + 24 +: 8] == omac_pkg::RF_CODE) t = 2'd2;
            end
            if (t != 2'd0) begin
                cc = '0;
                if (t == st) begin
                    if (sc < 3'd4) sc = sc + 1'b1;
                end else begin
                    st = t;
                    sc = 3'd1;
                end
                if (sc == 3'd4) lf = t;
            end else begin
                if (cc < 8'd128) cc = cc + 1'b1;
                if (cc == 8'd128) begin
                    sc = '0;
                    st = 2'd0;
                    lf = 2'd0;
                end
            end
        end
    end
    link_fault <= lf; seq_type <= st; seq_cnt <= sc; col_cnt <= cc;
    if (rst) begin
        link_fault <= 2'd0;
        seq_type   <= 2'd0;
        seq_cnt    <= '0;
        col_cnt    <= '0;
    end
end

endmodule

`resetall
