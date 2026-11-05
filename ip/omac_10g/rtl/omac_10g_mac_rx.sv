// SPDX-License-Identifier: MIT
//
// omac_10g_mac_rx - 64-bit RS + Ethernet MAC receive (in the recovered clock):
// XGMII 64-bit columns -> AXI-Stream frames without FCS (no tready).
//   start     /S/ in lane 0 (SFD in lane 7) or in lane 4 (SFD in lane 3 of the
//             next column); a start without the SFD is ignored
//   align     lane-4 frames are realigned by 4 bytes (byte 0 of the frame at
//             tdata[7:0])
//   end       the first control character of the frame: /T/ ends it normally,
//             anything else (/E/ from the PCS, ...) ends it as bad
//   FCS       CRC-32 over the frame including the FCS must leave the residue;
//             the last 4 bytes are stripped (one word of delay)
//   length    total length (with FCS) < MIN_FRAME: runt, bad; > MAX_FRAME: the
//             delivered frame is cut there with tuser = 1, the rest discarded
//   control   frames with EtherType 0x8808 are consumed; a good PAUSE (opcode
//             1, destination 01-80-C2-00-00-01 or mac_addr) pulses pause_ev
//             with its pause_time
// Output beats come out of two registers; tuser is valid on the tlast beat.
// Pipelined for 25GBASE-R: the running CRC over full words is a fixed 8-byte
// network; the end word is registered (e1), its partial-word CRC computed and
// registered in the next cycle (e2), and the verdict (residue, length, PAUSE)
// taken from e2 one more cycle later. The last beat of every frame therefore
// leaves one cycle after the end word (through the pending-beat register) and
// gets its tuser at the output register.
// Timestamp hook: `xts` arrives with each column; the frame's start time is
// the `xts` of the column with its /S/ (lane 0: the column with start + SFD;
// lane 4: the column before the SFD column), with `m_ts_lane4` = 1 for a
// lane-4 start. Both are held constant on every beat of the frame (`m_ts`,
// `m_ts_lane4` next to `m_tdata`). Frames that are not delivered (MAC Control,
// rx_enable = 0, nothing left after the FCS strip) never show a timestamp.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_mac_rx #(
    parameter int MIN_FRAME = 64,
    parameter int MAX_FRAME = 9600,
    parameter int TS_W      = 1
) (
    input  wire logic        clk,
    input  wire logic        rst,

    input  wire logic        xvalid,
    input  wire logic [63:0] xd,
    input  wire logic [7:0]  xc,
    input  wire logic [TS_W-1:0] xts,

    input  wire logic        rx_enable,
    input  wire logic [47:0] mac_addr,

    output logic             m_tvalid = 1'b0,
    output logic [63:0]      m_tdata,
    output logic [7:0]       m_tkeep,
    output logic             m_tlast,
    output logic             m_tuser,
    output logic [TS_W-1:0]  m_ts = '0,
    output logic             m_ts_lane4 = 1'b0,

    output logic             pause_ev,
    output logic [15:0]      pause_time,

    output logic             ev_good,
    output logic             ev_bad,
    output logic             ev_fcs_error,
    output logic             ev_runt,
    output logic             ev_oversize
);

import omac_pkg::*;

localparam int LW = $clog2(MAX_FRAME + 16) + 1;
localparam logic [47:0] PAUSE_DA = 48'h01_00_00_C2_80_01;

typedef enum logic [1:0] { R_IDLE, R_PRE4, R_FRAME, R_DISCARD } rst_t;
rst_t        st = R_IDLE;
logic        shift4 = 1'b0;
logic [63:0] prev_d;
logic [7:0]  prev_c;
logic [31:0] crc = CRC_INIT;
logic [LW-1:0] len = '0;
logic [63:0] dw;
logic        dw_v = 1'b0;
logic [1:0]  widx = '0;
logic        drop = 1'b0, is_ctrl = 1'b0, da_ok = 1'b0, op_pause = 1'b0;
logic [15:0] ptime = '0;
// pending tail beat (end word with 5..7 bytes)
logic        pend = 1'b0, pend_show = 1'b0;
logic [63:0] pend_d;
logic [3:0]  pend_n;
// first output register (the module output m_* is one register later)
logic        o_tvalid = 1'b0, o_tlast, o_tuser;
logic [63:0] o_tdata;
logic [7:0]  o_tkeep;
// end of frame: e1 = the end word registered, e2 = with its partial-word CRC
typedef enum logic [1:0] { E_NONE, E_LAST, E_DROP } ekind_t;
ekind_t      e1_kind = E_NONE, e_kind = E_NONE;
logic [31:0] e1_crc, e_crc;
logic [63:0] e1_w;
logic [3:0]  e1_p;
logic        e1_term, e1_runt, e1_over, e1_show, e1_drop, e1_pz;
logic [15:0] e1_ptime;
logic        e_term, e_runt, e_over, e_show, e_drop, e_pz;
logic [15:0] e_ptime;
wire         e_fcs_bad = (e_crc != CRC_RESIDUE);
wire         e_bad     = !e_term || e_fcs_bad || e_runt || e_over;
logic [31:0] e1_crc_w;
omac_crc32 #(.BYTES(8)) u_crc_end (.crc_in(e1_crc), .data(e1_w), .nbytes(e1_p), .crc_out(e1_crc_w));

// the aligned word of this column and its first control lane
wire  [63:0] w  = shift4 ? {xd[31:0], prev_d[63:32]} : xd;
wire  [7:0]  wc = shift4 ? {xc[3:0], prev_c[7:4]} : xc;
logic [3:0]  p;
always_comb begin
    p = 4'd8;
    for (int i = 7; i >= 0; i--) if (wc[i]) p = 4'(i);
end
logic [31:0] crc_w;   // after a full word
omac_crc32 #(.BYTES(8)) u_crc (.crc_in(crc), .data(w), .nbytes(4'd8), .crc_out(crc_w));

function automatic logic [7:0] keep_of(input logic [3:0] n);
    return 8'((16'h1 << n) - 1);
endfunction

wire start0 = xc[0] && xd[7:0] == XG_START && xc[7:1] == '0 && xd[63:56] == ETH_SFD;
wire start4 = xc[4] && xd[39:32] == XG_START && xc[7:5] == '0;
wire sfd4   = xc[3:0] == '0 && xd[31:24] == ETH_SFD;

// start-of-frame time: s4_ts = the time of the last column with /S/ in lane 4
// (used when the SFD follows in the next column), f_ts / f_l4 = the frame being
// delivered. f_ts changes at the start column of the next frame, after the last
// beat of the previous one has been registered into o_* (the pending tail beat
// leaves in the cycle of that column at the latest).
logic [TS_W-1:0] s4_ts = '0, f_ts = '0, o_ts = '0;
logic            f_l4 = 1'b0, o_l4 = 1'b0;
always_ff @(posedge clk) begin
    if (xvalid && start4) s4_ts <= xts;
    if (xvalid && (st == R_IDLE || st == R_PRE4)) begin
        if (st == R_PRE4 && sfd4) begin
            f_ts <= s4_ts;
            f_l4 <= 1'b1;
        end else if (start0) begin
            f_ts <= xts;
            f_l4 <= 1'b0;
        end
    end
    o_ts       <= f_ts;
    o_l4       <= f_l4;
    m_ts       <= o_ts;
    m_ts_lane4 <= o_l4;
end

always_ff @(posedge clk) begin
    logic          ov, runt, over, show, term, emit;
    logic [LW-1:0] tot;
    o_tvalid     <= 1'b0;
    e1_kind      <= E_NONE;
    e_kind       <= e1_kind;
    e_crc        <= e1_crc_w;
    e_term       <= e1_term;
    e_runt       <= e1_runt;
    e_over       <= e1_over;
    e_show       <= e1_show;
    e_drop       <= e1_drop;
    e_pz         <= e1_pz;
    e_ptime      <= e1_ptime;
    pause_ev     <= 1'b0;
    ev_good      <= 1'b0;
    ev_bad       <= 1'b0;
    ev_fcs_error <= 1'b0;
    ev_runt      <= 1'b0;
    ev_oversize  <= 1'b0;
    emit = 1'b0;
    // pending tail beat from the previous end word
    if (pend) begin
        pend <= 1'b0;
        if (pend_show) begin
            o_tvalid <= 1'b1;
            o_tdata  <= pend_d;
            o_tkeep  <= keep_of(pend_n);
            o_tlast  <= 1'b1;
            o_tuser  <= 1'b0;            // the verdict is added at the output register
            emit = 1'b1;
        end
    end
    if (xvalid) begin
        prev_d <= xd;
        prev_c <= xc;
        case (st)
            R_IDLE, R_PRE4: begin
                if (st == R_PRE4 && sfd4) begin
                    st     <= R_FRAME;
                    shift4 <= 1'b1;
                end else if (start0) begin
                    st     <= R_FRAME;
                    shift4 <= 1'b0;
                end else if (start4) begin
                    st <= R_PRE4;
                end else begin
                    st <= R_IDLE;
                end
                crc     <= CRC_INIT;
                len     <= '0;
                dw_v    <= 1'b0;
                widx    <= '0;
                is_ctrl <= 1'b0;
                da_ok   <= 1'b0;
                op_pause <= 1'b0;
                drop    <= !rx_enable;
            end
            default: begin   // R_FRAME, R_DISCARD
                show = !drop && !is_ctrl;
                if (p == 4'd8) begin
                    // a full word inside the frame
                    crc  <= crc_w;
                    len  <= len + LW'(8);
                    if (widx != 2'd3) widx <= widx + 1'b1;
                    if (widx == 2'd0) da_ok <= (w[47:0] == PAUSE_DA) || (w[47:0] == mac_addr);
                    if (widx == 2'd1) begin
                        is_ctrl  <= ({w[39:32], w[47:40]} == 16'h8808);
                        op_pause <= ({w[55:48], w[63:56]} == 16'h0001);
                        show = !drop && !({w[39:32], w[47:40]} == 16'h8808);
                    end
                    if (widx == 2'd2) ptime <= {w[7:0], w[15:8]};
                    ov = (len + LW'(8) > LW'(MAX_FRAME));
                    if (st == R_FRAME) begin
                        if (ov) begin
                            // cut the frame here
                            if (dw_v && show && !emit) begin
                                o_tvalid <= 1'b1;
                                o_tdata  <= dw;
                                o_tkeep  <= 8'hFF;
                                o_tlast  <= 1'b1;
                                o_tuser  <= 1'b1;
                            end
                            if (!is_ctrl && !drop) ev_bad <= 1'b1;
                            ev_oversize <= 1'b1;
                            dw_v <= 1'b0;
                            st   <= R_DISCARD;
                        end else begin
                            if (dw_v && show && !emit) begin
                                o_tvalid <= 1'b1;
                                o_tdata  <= dw;
                                o_tkeep  <= 8'hFF;
                                o_tlast  <= 1'b0;
                                o_tuser  <= 1'b0;
                            end
                            dw   <= w;
                            dw_v <= 1'b1;
                        end
                    end
                end else begin
                    // the end word: p data bytes, then a control character
                    term    = (w[8*p +: 8] == XG_TERM);
                    tot     = len + LW'(p);
                    runt    = tot < LW'(MIN_FRAME);
                    over    = tot > LW'(MAX_FRAME);
                    if (widx == 2'd1) show = !drop && !({w[39:32], w[47:40]} == 16'h8808) && !is_ctrl;
                    if (st == R_FRAME) begin
                        // the verdict follows two cycles later (e1 -> e)
                        e1_crc   <= crc;
                        e1_w     <= w;
                        e1_p     <= p;
                        e1_term  <= term;
                        e1_runt  <= runt;
                        e1_over  <= over;
                        e1_show  <= show;
                        e1_drop  <= drop;
                        e1_pz    <= is_ctrl && op_pause && da_ok;
                        e1_ptime <= ptime;
                        if (p >= 4'd5) begin
                            if (dw_v && show && !emit) begin
                                o_tvalid <= 1'b1;
                                o_tdata  <= dw;
                                o_tkeep  <= 8'hFF;
                                o_tlast  <= 1'b0;
                                o_tuser  <= 1'b0;
                            end
                            pend      <= 1'b1;
                            pend_show <= show;
                            pend_d    <= w;
                            pend_n    <= p - 4'd4;
                            e1_kind   <= E_LAST;
                        end else if (dw_v) begin
                            // the held word is the last one (FCS stripped): one cycle later
                            pend      <= 1'b1;
                            pend_show <= show;
                            pend_d    <= dw;
                            pend_n    <= p + 4'd4;
                            e1_kind   <= E_LAST;
                        end else begin
                            // nothing left after the FCS strip: dropped
                            e1_kind <= E_DROP;
                        end
                    end
                    dw_v <= 1'b0;
                    // a lane-4 frame ends one column late: this column may start the next
                    if (shift4 && p < 4'd4 && start4) st <= R_PRE4;
                    else st <= R_IDLE;
                    crc     <= CRC_INIT;
                    len     <= '0;
                    widx    <= '0;
                    is_ctrl <= 1'b0;
                    da_ok   <= 1'b0;
                    op_pause <= 1'b0;
                    drop    <= !rx_enable;
                end
            end
        endcase
    end
    // ---- verdict of the frame that ended two cycles ago ----
    if (e_kind != E_NONE) begin
        ev_fcs_error <= e_fcs_bad && e_term;
        ev_runt      <= e_runt;
        ev_oversize  <= e_over;
        if (e_kind == E_DROP) begin
            ev_bad <= !e_drop;
        end else if (e_show) begin
            ev_good <= !e_bad;
            ev_bad  <= e_bad;
        end
        // a good PAUSE frame (consumed, never shown)
        if (e_pz && !e_bad) begin
            pause_ev   <= 1'b1;
            pause_time <= e_ptime;
        end
    end
    // ---- output register: the last beat of the frame gets its verdict ----
    m_tvalid <= o_tvalid;
    m_tdata  <= o_tdata;
    m_tkeep  <= o_tkeep;
    m_tlast  <= o_tlast;
    m_tuser  <= o_tuser || (o_tvalid && o_tlast && e_kind == E_LAST && e_bad);
    if (rst) begin
        st       <= R_IDLE;
        dw_v     <= 1'b0;
        pend     <= 1'b0;
        e1_kind  <= E_NONE;
        e_kind   <= E_NONE;
        m_tvalid <= 1'b0;
        o_tvalid <= 1'b0;
        pause_ev <= 1'b0;
        ev_good  <= 1'b0;
        ev_bad   <= 1'b0;
        ev_fcs_error <= 1'b0;
        ev_runt  <= 1'b0;
        ev_oversize  <= 1'b0;
    end
end

endmodule

`resetall
