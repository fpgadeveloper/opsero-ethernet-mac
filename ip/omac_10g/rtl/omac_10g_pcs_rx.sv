// SPDX-License-Identifier: MIT
//
// omac_10g_pcs_rx - 10GBASE-R / 25GBASE-R PCS receive (IEEE 802.3 clause 49),
// in the recovered clock: block lock (figure 49-14, gearbox slip), BER monitor
// (figure 49-15), descrambler, 64B/66B decoder (omac_pkg::dec66) and the
// receive state machine of figure 49-17 with its one-block look-ahead (a
// terminate block is only accepted when the next block is a start or a control
// block). Out-of-sequence or invalid blocks are replaced by the error column;
// without block lock or with hi_ber the output is the Local Fault column.
// One output column per valid input block, latency 4 valid blocks.
// Timestamp hook: `ts_in` is sampled with every valid input block (the cycle
// the block is on the transceiver interface) and travels with the block, so
// `xts` is the value that was on `ts_in` when the block of the column now on
// `xd`/`xc` arrived (constant ts_in = 0 when the hooks are off: no logic).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_pcs_rx #(
    parameter int SLIP_WAIT      = 256,
    parameter int BER_TIMER_CLKS = 19532,
    parameter int BER_THRESH     = 16,
    parameter int TS_W           = 1
) (
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic        valid,
    input  wire logic [1:0]  hdr,
    input  wire logic [63:0] data,
    input  wire logic [TS_W-1:0] ts_in,

    output wire logic        slip,
    output wire logic        block_lock,
    output wire logic        hi_ber,

    output logic             xvalid,
    output logic [63:0]      xd,
    output logic [7:0]       xc,
    output logic [TS_W-1:0]  xts,
    output logic             ev_bad_block,
    output logic             ev_seq_error
);

import omac_pkg::*;

localparam logic [63:0] LF_D = {LF_CODE, 16'h0000, XG_SEQ, LF_CODE, 16'h0000, XG_SEQ};
localparam logic [7:0]  LF_C = 8'h11;
localparam logic [63:0] E_D  = {8{XG_ERROR}};

omac_block_lock #(.SLIP_WAIT(SLIP_WAIT)) u_lock (
    .clk(clk), .rst(rst), .valid(valid), .hdr(hdr), .slip(slip), .lock(block_lock));

omac_ber_mon #(.TIMER_CLKS(BER_TIMER_CLKS), .THRESH(BER_THRESH)) u_ber (
    .clk(clk), .rst(rst), .lock(block_lock), .valid(valid), .hdr(hdr),
    .hi_ber(hi_ber), .invalid_sh());

// stage 1: descramble (the descrambler registers its output)
logic [63:0] dsc;
logic [1:0]  hdr1 = '0;
logic        v1 = 1'b0;
logic [TS_W-1:0] ts1 = '0, ts2 = '0, cur_ts = '0;
omac_descrambler u_dsc (.clk(clk), .en(valid), .din(data), .dout(dsc));
always_ff @(posedge clk) begin
    v1 <= valid;
    if (valid) hdr1 <= hdr;
    if (valid) ts1  <= ts_in;
    if (rst) v1 <= 1'b0;
end

// stage 2: decode
logic        v2 = 1'b0;
rtype_t      rt2 = RT_E;
logic [63:0] d2;
logic [7:0]  c2;
logic [74:0] dec;
assign dec = dec66(hdr1, dsc);
always_ff @(posedge clk) begin
    v2 <= v1;
    if (v1) begin
        ts2 <= ts1;
        rt2 <= rtype_t'(dec[74:72]);
        c2  <= dec[71:64];
        d2  <= dec[63:0];
    end
    if (rst) v2 <= 1'b0;
end

// stage 3: receive state machine; `cur` waits for the next block (look-ahead)
typedef enum logic [2:0] { RX_INIT, RX_C, RX_D, RX_T, RX_E } rxs_t;
rxs_t        st = RX_INIT;
logic        cur_v = 1'b0;
rtype_t      cur_rt = RT_E;
logic [63:0] cur_d;
logic [7:0]  cur_c;

wire up = block_lock && !hi_ber;

always_ff @(posedge clk) begin
    rxs_t nst;
    xvalid       <= 1'b0;
    ev_bad_block <= 1'b0;
    ev_seq_error <= 1'b0;
    if (v2) begin
        cur_v  <= 1'b1;
        cur_rt <= rt2;
        cur_d  <= d2;
        cur_c  <= c2;
        cur_ts <= ts2;
        if (cur_v) begin
            xvalid <= 1'b1;
            xts    <= cur_ts;
            if (!up) begin
                nst = RX_INIT;
                xd  <= LF_D;
                xc  <= LF_C;
            end else begin
                nst = RX_E;
                case (cur_rt)
                    RT_C: if (st != RX_D) nst = RX_C;
                    RT_S: if (st != RX_D) nst = RX_D;
                    RT_D: if (st == RX_D || st == RX_E) nst = RX_D;
                    RT_T: if ((st == RX_D || st == RX_E) && (rt2 == RT_S || rt2 == RT_C)) nst = RX_T;
                    default: nst = RX_E;
                endcase
                if (nst == RX_E) begin
                    xd <= E_D;
                    xc <= 8'hFF;
                    ev_bad_block <= 1'b1;
                    ev_seq_error <= (cur_rt != RT_E);
                end else begin
                    xd <= cur_d;
                    xc <= cur_c;
                end
            end
            st <= nst;
        end
    end
    if (rst) begin
        st     <= RX_INIT;
        cur_v  <= 1'b0;
        xvalid <= 1'b0;
        ev_bad_block <= 1'b0;
        ev_seq_error <= 1'b0;
    end
end

endmodule

`resetall
