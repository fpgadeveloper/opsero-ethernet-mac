// SPDX-License-Identifier: MIT
//
// omac_40g_pcs_rx - 40GBASE-R PCS receive after the per-lane block and AM lock
// (IEEE 802.3 clause 82), in the common receive clock:
//   deskew     the four lane FIFOs (written in the lanes' recovered clocks) are
//              read so that the alignment markers of all lanes leave together:
//              with every lane AM-locked and the four lane numbers distinct, each FIFO is drained up to its next marker and
//              held there; once all four hold a marker the lanes are aligned
//              (align_status). If the last marker arrives more than DESKEW_MAX
//              cycles (blocks) after the first, the attempt fails (ev_skew_fail)
//              and the next period is tried. While aligned, markers must leave
//              all lanes in the same cycle (else alignment is dropped); a lane
//              FIFO running empty stalls all four. Before every attempt the lane
//              FIFOs are flushed (flush_wr / flush_rd reset both sides): a lane
//              that held a marker in a failed attempt would otherwise keep that
//              backlog for good (its FIFO is written and read at the same rate)
//   reorder    block j of the output = the lane whose marker said PCS lane j:
//              the physical lane order does not matter
//   AM removal the marker column is not passed on
//   BER        BER monitor over the sync headers of all lanes (40GBASE-R: 97
//              invalid headers within 1.25 ms set hi_ber)
//   descramble the aggregate stream, PCS lane 0 first
//   decode     clause 82 block subset (omac_40g_pkg::dec66_r4) and the receive
//              state machine of clause 82 per block, four blocks per cycle in
//              order, with the one-block look-ahead for /T/ (the next block must
//              be /S/ or /C/): out-of-sequence blocks become /E/ columns
//   fault      without alignment or with hi_ber the output is Local Fault
//              columns, one beat per cycle
// Output: four XLGMII 8-byte columns per valid cycle (xvalid has gaps: the
// marker cycle and FIFO stalls).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_40g_pcs_rx #(
    parameter int DESKEW_MAX     = 32,
    parameter int BER_TIMER_CLKS = 195313,
    parameter int BER_THRESH     = 97
) (
    input  wire logic         clk,
    input  wire logic         rst,

    // lane FIFOs (physical lane order): {am_ok, am, block[65:0]}
    input  wire logic [3:0]   l_valid,
    input  wire logic [271:0] l_data,
    output logic      [3:0]   l_rd,
    output logic              flush_wr,      // reset the write side of the lane FIFOs (synchronise per lane)
    output logic              flush_rd,      // reset the read side (covers flush_wr plus the synchroniser)
    // lane status (synchronised into clk)
    input  wire logic [3:0]   l_block_lock,
    input  wire logic [3:0]   l_am_lock,
    input  wire logic [7:0]   l_lane_id,

    output logic              align_status,
    output wire logic         hi_ber,
    output logic      [7:0]   lane_map,      // PCS lane of physical lane p at [2p +: 2] (latched at alignment)
    output logic      [6:0]   skew,          // marker arrival spread of the last alignment (blocks)
    output logic              ev_skew_fail,

    output logic              xvalid,
    output logic      [255:0] xd,
    output logic      [31:0]  xc,
    output logic              ev_bad_block,
    output logic              ev_seq_error
);

import omac_pkg::*;
import omac_40g_pkg::*;

localparam logic [63:0] LF_D = {{4{XG_IDLE}}, LF_CODE, 16'h0000, XG_SEQ};
localparam logic [7:0]  LF_C = 8'hF1;

// ---------------- deskew ----------------
typedef enum logic [1:0] { D_RESET, D_FLUSH, D_SEARCH, D_ALIGNED } dst_t;
dst_t       dst = D_RESET;
logic [4:0] fl_cnt = '0;
assign flush_wr = (dst == D_FLUSH) && (fl_cnt < 5'd8);
assign flush_rd = (dst == D_FLUSH) && (fl_cnt < 5'd20);
logic [6:0] sk_cnt = '0;
logic       sk_run = 1'b0;
logic [1:0] sel [4];             // output block j <- physical lane sel[j]

wire [3:0] l_am  = {l_data[270], l_data[202], l_data[134], l_data[66]};   // marker position
wire [3:0] l_amk = {l_data[271], l_data[203], l_data[135], l_data[67]};   // ... and a valid marker
wire [3:0] l_hd  = l_am & l_amk;                                          // held in the search

logic ids_ok;
always_comb begin
    logic [3:0] seen;
    seen = '0;
    for (int p = 0; p < 4; p++) seen[l_lane_id[2*p +: 2]] = 1'b1;
    ids_ok = (seen == 4'hF);
end
wire lanes_up = (&l_block_lock) && (&l_am_lock) && ids_ok;

logic        r0_v = 1'b0;
logic [65:0] r0_blk [4];

always_comb begin
    l_rd = '0;
    case (dst)
        D_RESET, D_FLUSH: l_rd = l_valid;
        D_SEARCH: begin
            for (int p = 0; p < 4; p++) l_rd[p] = l_valid[p] && !l_hd[p];
            if ((&l_valid) && (&l_hd)) l_rd = 4'hF;                       // aligned: markers leave together
            else if (sk_run && sk_cnt >= 7'(DESKEW_MAX)) l_rd = l_valid; // too much skew: drop the markers
        end
        default:  if (&l_valid) l_rd = 4'hF;
    endcase
    if (!lanes_up) l_rd = l_valid;
end

always_ff @(posedge clk) begin
    r0_v         <= 1'b0;
    ev_skew_fail <= 1'b0;
    case (dst)
        D_RESET: begin
            align_status <= 1'b0;
            sk_run <= 1'b0;
            sk_cnt <= '0;
            fl_cnt <= '0;
            if (lanes_up) dst <= D_FLUSH;
        end
        D_FLUSH: begin
            fl_cnt <= fl_cnt + 1'b1;
            sk_run <= 1'b0;
            sk_cnt <= '0;
            if (fl_cnt == 5'd31) dst <= D_SEARCH;
        end
        D_SEARCH: begin
            if ((&l_valid) && (&l_hd)) begin
                dst          <= D_ALIGNED;
                align_status <= 1'b1;
                skew         <= sk_run ? sk_cnt : 7'd0;
                for (int j = 0; j < 4; j++)
                    for (int p = 0; p < 4; p++) if (l_lane_id[2*p +: 2] == 2'(j)) sel[j] <= 2'(p);
                lane_map <= l_lane_id;
                sk_run <= 1'b0;
                sk_cnt <= '0;
            end else if (sk_run && sk_cnt >= 7'(DESKEW_MAX)) begin
                ev_skew_fail <= 1'b1;
                sk_run <= 1'b0;
                sk_cnt <= '0;
                dst    <= D_FLUSH;
                fl_cnt <= '0;
            end else if (sk_run) begin
                sk_cnt <= sk_cnt + 1'b1;
            end else if (|(l_valid & l_hd)) begin
                sk_run <= 1'b1;          // the first marker is waiting: count the spread
                sk_cnt <= 7'd1;
            end
        end
        default: begin   // D_ALIGNED
            if (&l_valid) begin
                if (&l_am) begin
                    // marker column: removed
                end else if (|l_am) begin
                    dst          <= D_FLUSH;       // markers no longer line up
                    fl_cnt       <= '0;
                    align_status <= 1'b0;
                end else begin
                    r0_v <= 1'b1;
                    for (int j = 0; j < 4; j++) begin
                        case (sel[j])
                            2'd0:    r0_blk[j] <= l_data[0   +: 66];
                            2'd1:    r0_blk[j] <= l_data[68  +: 66];
                            2'd2:    r0_blk[j] <= l_data[136 +: 66];
                            default: r0_blk[j] <= l_data[204 +: 66];
                        endcase
                    end
                end
            end
        end
    endcase
    if (!lanes_up && dst != D_RESET) begin
        dst          <= D_RESET;
        align_status <= 1'b0;
        r0_v         <= 1'b0;
    end
    if (rst) begin
        dst          <= D_RESET;
        align_status <= 1'b0;
        r0_v         <= 1'b0;
        lane_map     <= '0;
        skew         <= '0;
        ev_skew_fail <= 1'b0;
    end
end

// ---------------- BER monitor (all lanes) ----------------
omac_ber_mon #(.TIMER_CLKS(BER_TIMER_CLKS), .THRESH(BER_THRESH), .N(4)) u_ber (
    .clk(clk), .rst(rst), .lock(align_status), .valid(r0_v),
    .hdr({r0_blk[3][1:0], r0_blk[2][1:0], r0_blk[1][1:0], r0_blk[0][1:0]}),
    .hi_ber(hi_ber), .invalid_sh());

wire up = align_status && !hi_ber;

// ---------------- descramble ----------------
logic        r1_v = 1'b0;
logic [1:0]  r1_hdr [4];
logic [63:0] r1_pay [4];
logic [57:0] dsc = '0;
always_ff @(posedge clk) begin
    logic [57:0]  st;
    logic [121:0] r;
    r1_v <= r0_v;
    if (r0_v) begin
        st = dsc;
        for (int j = 0; j < 4; j++) begin
            r = descramble(st, r0_blk[j][65:2]);
            st = r[121:64];
            r1_pay[j] <= r[63:0];
            r1_hdr[j] <= r0_blk[j][1:0];
        end
        dsc <= st;
    end
    if (rst) r1_v <= 1'b0;
end

// ---------------- decode ----------------
logic        r2_v = 1'b0;
rtype_t      r2_rt [4];
logic [63:0] r2_d [4];
logic [7:0]  r2_c [4];
always_ff @(posedge clk) begin
    logic [74:0] x;
    r2_v <= r1_v;
    if (r1_v) begin
        for (int j = 0; j < 4; j++) begin
            x = dec66_r4(r1_hdr[j], r1_pay[j]);
            r2_rt[j] <= rtype_t'(x[74:72]);
            r2_c[j]  <= x[71:64];
            r2_d[j]  <= x[63:0];
        end
    end
    if (rst) r2_v <= 1'b0;
end

// ---------------- receive state machine , one beat of look-ahead ----------------
typedef enum logic [2:0] { RX_INIT, RX_C, RX_D, RX_T, RX_E } rxs_t;
rxs_t        rst_q = RX_INIT;
logic        cur_v = 1'b0;
rtype_t      cur_rt [4];
logic [63:0] cur_d [4];
logic [7:0]  cur_c [4];

always_ff @(posedge clk) begin
    rxs_t   s, ns;
    rtype_t nxt;
    logic   bad, seq;
    xvalid       <= 1'b0;
    ev_bad_block <= 1'b0;
    ev_seq_error <= 1'b0;
    if (!up) begin
        // no alignment or high BER: Local Fault, one beat per cycle
        xvalid <= 1'b1;
        for (int j = 0; j < 4; j++) begin
            xd[64*j +: 64] <= LF_D;
            xc[8*j +: 8]   <= LF_C;
        end
        rst_q <= RX_INIT;
        cur_v <= 1'b0;
    end else if (r2_v) begin
        cur_v <= 1'b1;
        for (int j = 0; j < 4; j++) begin
            cur_rt[j] <= r2_rt[j];
            cur_d[j]  <= r2_d[j];
            cur_c[j]  <= r2_c[j];
        end
        if (cur_v) begin
            xvalid <= 1'b1;
            s   = rst_q;
            bad = 1'b0;
            seq = 1'b0;
            for (int j = 0; j < 4; j++) begin
                nxt = (j < 3) ? cur_rt[j + 1] : r2_rt[0];
                ns  = RX_E;
                case (cur_rt[j])
                    RT_C: if (s != RX_D) ns = RX_C;
                    RT_S: if (s != RX_D) ns = RX_D;
                    RT_D: if (s == RX_D || s == RX_E) ns = RX_D;
                    RT_T: if ((s == RX_D || s == RX_E) && (nxt == RT_S || nxt == RT_C)) ns = RX_T;
                    default: ns = RX_E;
                endcase
                if (ns == RX_E) begin
                    xd[64*j +: 64] <= {8{XG_ERROR}};
                    xc[8*j +: 8]   <= 8'hFF;
                    bad = 1'b1;
                    if (cur_rt[j] != RT_E) seq = 1'b1;
                end else begin
                    xd[64*j +: 64] <= cur_d[j];
                    xc[8*j +: 8]   <= cur_c[j];
                end
                s = ns;
            end
            rst_q        <= s;
            ev_bad_block <= bad;
            ev_seq_error <= seq;
        end
    end
    if (rst) begin
        rst_q  <= RX_INIT;
        cur_v  <= 1'b0;
        xvalid <= 1'b0;
        ev_bad_block <= 1'b0;
        ev_seq_error <= 1'b0;
    end
end

endmodule

`resetall
