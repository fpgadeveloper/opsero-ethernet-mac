// SPDX-License-Identifier: MIT
//
// omac_40g_lane_rx - receive side of one 40GBASE-R physical lane, in the lane's
// recovered clock (IEEE 802.3 clause 82):
//   block lock   omac_block_lock (the clause 49 lock state machine), gearbox slip
//   AM lock      clause 82: a block matching any lane's alignment marker is a
//                candidate; the same marker AM_PERIOD blocks later gives AM lock
//                and the PCS lane number of this physical lane; while locked the
//                marker is checked every AM_PERIOD blocks, 4 mismatches in a row
//                (am_invld_cnt = 4) drop AM lock
//   BIP          BIP3 over the lane's blocks from the previous marker (inclusive)
//                compared with the BIP3 field of each marker; a mismatch
//                pulses ev_bip_error (the lane's bit error indicator)
// Output: every block while block lock is held, to the lane's deskew FIFO, with
// two flags while AM lock is held: o_am on the blocks at the marker positions
// (removed downstream even if corrupted) and o_amok when that block really is
// this lane's marker (only those are used to align the lanes).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_40g_lane_rx #(
    parameter int AM_PERIOD = 16384,
    parameter int SLIP_WAIT = 256
) (
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic        valid,
    input  wire logic [1:0]  hdr,
    input  wire logic [63:0] data,
    output wire logic        slip,

    output wire logic        block_lock,
    output logic             am_lock,
    output logic      [1:0]  lane_id,
    output logic             ev_bip_error,

    output logic             o_valid,
    output logic             o_am,
    output logic             o_amok,
    output logic      [65:0] o_blk
);

import omac_pkg::*;
import omac_40g_pkg::*;

localparam int AW = $clog2(AM_PERIOD);

omac_block_lock #(.SLIP_WAIT(SLIP_WAIT)) u_lock (
    .clk(clk), .rst(rst), .valid(valid), .hdr(hdr), .slip(slip), .lock(block_lock));

typedef enum logic [1:0] { M_FIND, M_COUNT, M_LOCKED } mst_t;
mst_t          st = M_FIND;
logic [AW-1:0] cnt = '0;          // blocks since the candidate / last marker
logic [1:0]    cand = '0;
logic [2:0]    invld = '0;
logic [7:0]    acc = '0;
logic          acc_ok = 1'b0;     // acc covers a whole period

wire  [65:0]   b  = {data, hdr};
wire  [2:0]    am = am_match(b);
wire           at_am = (cnt == AW'(AM_PERIOD - 1));

always_ff @(posedge clk) begin
    o_valid      <= 1'b0;
    ev_bip_error <= 1'b0;
    if (valid && block_lock) begin
        o_valid <= 1'b1;
        o_blk   <= b;
        o_am    <= 1'b0;
        o_amok  <= 1'b0;
        cnt     <= cnt + 1'b1;
        acc     <= acc ^ bip8(b);
        case (st)
            M_FIND: begin
                if (am[2]) begin
                    st   <= M_COUNT;
                    cand <= am[1:0];
                    cnt  <= '0;
                end
            end
            M_COUNT: begin
                if (at_am) begin
                    if (am[2] && am[1:0] == cand) begin
                        st      <= M_LOCKED;
                        am_lock <= 1'b1;
                        lane_id <= cand;
                        invld   <= '0;
                        o_am    <= 1'b1;
                        o_amok  <= 1'b1;
                        acc     <= bip8(b);
                        acc_ok  <= 1'b1;
                    end else if (am[2]) begin
                        cand <= am[1:0];     // another marker: a new candidate
                    end else begin
                        st <= M_FIND;
                    end
                    cnt <= '0;
                end
            end
            default: begin   // M_LOCKED
                if (at_am) begin
                    o_am <= 1'b1;
                    cnt  <= '0;
                    acc  <= bip8(b);
                    if (am[2] && am[1:0] == lane_id) begin
                        invld <= '0;
                        o_amok <= 1'b1;
                        ev_bip_error <= acc_ok && (b[33:26] != acc);
                        acc_ok <= 1'b1;
                    end else if (invld == 3'd3) begin
                        st      <= M_FIND;
                        am_lock <= 1'b0;
                        acc_ok  <= 1'b0;
                    end else begin
                        invld  <= invld + 1'b1;
                        acc_ok <= 1'b0;
                    end
                end
            end
        endcase
    end
    if (rst || !block_lock) begin
        st      <= M_FIND;
        am_lock <= 1'b0;
        acc_ok  <= 1'b0;
        invld   <= '0;
    end
    if (rst) begin
        o_valid <= 1'b0;
        ev_bip_error <= 1'b0;
        lane_id <= '0;
    end
end

endmodule

`resetall
