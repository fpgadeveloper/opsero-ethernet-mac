// SPDX-License-Identifier: MIT
//
// omac_40g_mac_tx - 256-bit Ethernet MAC + RS transmit: AXI-Stream frames (no
// FCS, byte 0 at tdata[7:0]) -> XLGMII, four 8-byte columns per cycle.
//   arbiter  at frame boundaries a requested PAUSE frame first, then user frames
//            (while tx_enable and not hold)
//   pad      frames shorter than 60 bytes are padded with zeros (TX_PAD = 1)
//   FCS      CRC-32 in a 3-stage pipeline: the running state over full beats is
//            a one-cycle loop (zero-state CRC of beat ^ state); the last beat's
//            CRC is computed with the beat right-aligned (omac_40g_pkg identities)
//            and appended (one extra beat when the last beat has > 28 bytes)
//   columns  a column packer: /S/ (with preamble + SFD) only in lane 0 of an
//            8-byte column (IEEE 802.3 clauses 81 / 82: XLGMII start
//            alignment), so a frame may start in any of the four columns of a
//            beat and two frames can share a beat; data columns, /T/ column,
//            idles. Inter-packet gap: from /T/ (inclusive) to the next /S/ at
//            least 12 - DIC_MAX + dic bytes, /S/ on an 8-byte boundary; the
//            deficit idle count dic (0..DIC_MAX; 7 for 8-byte alignment, so
//            every gap is 5..19 bytes) keeps the average at 12 bytes (the
//            clause 46 / 81 deficit idle count, with 8-byte alignment). Up to 8 columns are buffered, so frames follow each
//            other on the wire without idle columns beyond the gap.
//   ce       the whole pipeline (and s_tready) advances only while ce = 1: the
//            PCS holds it one cycle in every AM_PERIOD to insert the alignment
//            markers (four 66-bit blocks = one beat of wire time); the MAC thus
//            sends one beat less per AM period instead of the PCS deleting idles.
// Once a frame has started on the wire its beats must keep coming; if the next
// column of a frame is due and no beat is there (the user dropped tvalid), the
// frame is ended with an error column (/E/ in every lane), ev_underflow pulses
// and the rest is discarded; tuser (abort) on a beat does the same (ev_abort).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_40g_mac_tx #(
    parameter bit TX_PAD   = 1'b1,
    parameter bit PAUSE_EN = 1'b1,
    parameter int DIC_MAX  = 7
) (
    input  wire logic         clk,
    input  wire logic         rst,
    input  wire logic         ce,

    input  wire logic [255:0] s_tdata,
    input  wire logic [31:0]  s_tkeep,
    input  wire logic         s_tvalid,
    output wire logic         s_tready,
    input  wire logic         s_tlast,
    input  wire logic         s_tuser,

    input  wire logic         tx_enable,
    input  wire logic         hold,

    input  wire logic         pause_req,
    input  wire logic         pause_req_xon,
    output logic              pause_ack,
    input  wire logic [15:0]  pause_quanta,
    input  wire logic [47:0]  mac_addr,

    output logic [255:0]      xd,
    output logic [31:0]       xc,

    output logic              ev_frame,
    output logic              ev_pause,
    output logic              ev_underflow,
    output logic              ev_abort
);

import omac_pkg::*;
import omac_40g_pkg::*;

localparam logic [71:0] COL_IDLE = {8'hFF, {8{XG_IDLE}}};
localparam logic [71:0] COL_ERR  = {8'hFF, {8{XG_ERROR}}};
localparam logic [71:0] COL_S    = {8'h01, ETH_SFD, {6{ETH_PRE}}, XG_START};

// ---------------- pipeline control ----------------
logic adv;            // P, F1, F2 advance
logic m_v = 1'b0, m_last, m_err, m_extra = 1'b0;
logic [255:0] m_d;
logic [5:0]   m_n;
logic pk_take;
wire  m_free = !m_v || pk_take;
assign adv = ce && m_free && !m_extra;

// ---------------- arbiter ----------------
// Decides at every frame boundary without a dead cycle (a 64-byte frame is only
// two beats): a requested PAUSE frame first, else user beats while tx_enable and
// not hold.
logic u_busy = 1'b0;           // inside a user frame
logic p_sel  = 1'b0;           // the PAUSE frame is being sent

logic [255:0] pf_tdata;
logic [31:0]  pf_tkeep;
logic         pf_tvalid, pf_tlast, pf_busy;
logic         a_ready;
wire          boundary = !u_busy && !p_sel;
wire          p_want   = PAUSE_EN && pause_req && tx_enable;
wire          pf_start = boundary && p_want && !pf_busy;
wire          u_ok     = u_busy || (boundary && !p_want && tx_enable && !hold);

omac_pause_frame #(.DATA_WIDTH(256)) u_pf (
    .clk(clk), .rst(rst), .start(pf_start),
    .pause_time(pause_req_xon ? 16'd0 : pause_quanta), .mac_addr(mac_addr), .busy(pf_busy),
    .m_axis_tdata(pf_tdata), .m_axis_tkeep(pf_tkeep), .m_axis_tvalid(pf_tvalid),
    .m_axis_tready(p_sel && a_ready), .m_axis_tlast(pf_tlast));

wire          a_valid = p_sel ? pf_tvalid : (u_ok && s_tvalid);
wire  [255:0] a_data  = p_sel ? pf_tdata : s_tdata;
wire  [31:0]  a_keep  = p_sel ? pf_tkeep : s_tkeep;
wire          a_last  = p_sel ? pf_tlast : s_tlast;
wire          a_user  = !p_sel && s_tuser;
assign s_tready = !p_sel && u_ok && a_ready;

always_ff @(posedge clk) begin
    pause_ack <= 1'b0;
    ev_pause  <= 1'b0;
    if (pf_start) begin
        p_sel     <= 1'b1;
        pause_ack <= 1'b1;
    end
    if (!p_sel && u_ok && s_tvalid && a_ready) u_busy <= !s_tlast;
    if (p_sel && pf_tvalid && a_ready && pf_tlast) begin
        p_sel    <= 1'b0;
        ev_pause <= 1'b1;
    end
    if (rst) begin
        u_busy    <= 1'b0;
        p_sel     <= 1'b0;
        pause_ack <= 1'b0;
        ev_pause  <= 1'b0;
    end
end

// ---------------- P: pad ----------------
logic         p_v = 1'b0, p_last = 1'b0, p_err = 1'b0, p_first = 1'b1;
logic [255:0] p_d;
logic [5:0]   p_n;
logic         pad = 1'b0;
logic         nxt_first = 1'b1;
logic [6:0]   pcnt = '0;          // bytes of the frame so far: 0, 32, 64 (saturating)

function automatic logic [5:0] keep_n(input logic [31:0] k);
    logic [5:0] n;
    n = 6'd0;
    for (int i = 0; i < 32; i++) if (k[i]) n = 6'(i + 1);
    return n;
endfunction

assign a_ready = adv && !pad;

always_ff @(posedge clk) begin
    logic [5:0] n;
    if (adv) begin
        p_v <= 1'b0;
        if (pad) begin
            // the second beat of a padded frame: 28 zero bytes (32 + 28 = 60)
            p_v     <= 1'b1;
            p_d     <= '0;
            p_n     <= 6'd28;
            p_last  <= 1'b1;
            p_err   <= 1'b0;
            p_first <= 1'b0;
            pad     <= 1'b0;
            pcnt    <= '0;
            nxt_first <= 1'b1;
        end else if (a_valid) begin
            n = a_last ? keep_n(a_keep) : 6'd32;
            p_v     <= 1'b1;
            p_d     <= a_data & byte_mask(6'd0, n);
            p_err   <= a_user;
            p_first <= nxt_first;
            nxt_first <= a_last;
            if (a_last && TX_PAD && (pcnt + 7'(n) < 7'd60)) begin
                if (pcnt != '0) begin
                    p_n    <= 6'd28;        // second beat: pad to 60
                    p_last <= 1'b1;
                    pcnt   <= '0;
                end else begin
                    p_n    <= 6'd32;        // first beat: pad it, then a 28-byte zero beat
                    p_last <= 1'b0;
                    pad    <= 1'b1;
                    pcnt   <= 7'd32;
                    nxt_first <= 1'b0;
                end
            end else begin
                p_n    <= n;
                p_last <= a_last;
                pcnt   <= a_last ? 7'd0 : ((pcnt >= 7'd64) ? pcnt : pcnt + 7'd32);
            end
        end
    end
    if (rst) begin
        p_v  <= 1'b0;
        pad  <= 1'b0;
        pcnt <= '0;
        nxt_first <= 1'b1;
    end
end

// ---------------- F1: running CRC state ----------------
logic         f1_v = 1'b0, f1_last, f1_err;
logic [255:0] f1_d;
logic [5:0]   f1_n;
logic [31:0]  f1_s;           // CRC register before this beat
logic [31:0]  s_run = CRC_INIT;
wire  [31:0]  s_after = crc_z32(f1_d ^ {224'd0, f1_s});   // after a full (non-last) beat
wire          f1_full = f1_v && !f1_last;

always_ff @(posedge clk) begin
    if (adv) begin
        if (f1_full) s_run <= s_after;
        f1_v    <= p_v;
        f1_d    <= p_d;
        f1_n    <= p_n;
        f1_last <= p_last;
        f1_err  <= p_err;
        f1_s    <= p_first ? CRC_INIT : (f1_full ? s_after : s_run);
    end
    if (rst) f1_v <= 1'b0;
end

// ---------------- F2: last beat right-aligned ----------------
logic         f2_v = 1'b0, f2_last, f2_err;
logic [255:0] f2_d, f2_y;
logic [5:0]   f2_n;
logic [31:0]  f2_corr;

always_ff @(posedge clk) begin
    logic [255:0] x;
    if (adv) begin
        f2_v    <= f1_v;
        f2_d    <= f1_d;
        f2_n    <= f1_n;
        f2_last <= f1_last;
        f2_err  <= f1_err;
        x        = (f1_d ^ {224'd0, f1_s}) & byte_mask(6'd0, f1_n);
        f2_y    <= x << (8 * (32 - int'(f1_n)));
        f2_corr <= (f1_n < 6'd4) ? (f1_s >> (8 * int'(f1_n))) : 32'd0;
    end
    if (rst) f2_v <= 1'b0;
end

// ---------------- M: FCS merge ----------------
wire  [31:0]  fcs = ~(crc_z32(f2_y) ^ f2_corr);
logic [287:0] fcs_sh;
logic [31:0]  ex_d;
logic [5:0]   ex_n;
assign fcs_sh = {256'd0, fcs} << (8 * int'(f2_n));

always_ff @(posedge clk) begin
    if (ce && m_free) begin
        if (m_extra) begin
            m_v     <= 1'b1;
            m_d     <= {224'd0, ex_d};
            m_n     <= ex_n;
            m_last  <= 1'b1;
            m_err   <= 1'b0;
            m_extra <= 1'b0;
        end else begin
            m_v   <= f2_v;
            m_err <= f2_err;
            if (!f2_last) begin
                m_d    <= f2_d;
                m_n    <= 6'd32;
                m_last <= 1'b0;
            end else if (f2_n <= 6'd28) begin
                m_d    <= f2_d | fcs_sh[255:0];
                m_n    <= f2_n + 6'd4;
                m_last <= 1'b1;
            end else begin
                m_d     <= f2_d | fcs_sh[255:0];
                m_n     <= 6'd32;
                m_last  <= 1'b0;
                m_extra <= f2_v;
                ex_d    <= fcs_sh[287:256];
                ex_n    <= f2_n - 6'd28;
            end
        end
    end
    if (rst) begin
        m_v     <= 1'b0;
        m_extra <= 1'b0;
    end
end

// ---------------- column packer ----------------
typedef enum logic [1:0] { K_IDLE, K_FRAME, K_DRAIN } kst_t;
kst_t        kst = K_IDLE;
logic [71:0] buff [8];
logic [3:0]  cnt = '0;          // columns in buff (0..8)
logic [6:0]  gap = 7'd64;       // gap bytes since /T/ (inclusive), saturating at 64
logic [2:0]  dic = '0;

// columns of the beat in M: data columns, the /T/ column of a last beat
logic [71:0] mcol [5];
logic [2:0]  m_f;               // full data columns of a last beat (0..4)
logic [2:0]  m_j;               // data bytes in the /T/ column
logic [3:0]  m_ncols;           // columns of the beat (4, or f + 1 for a last beat)
always_comb begin
    m_f = 3'(m_n >> 3);
    m_j = 3'(m_n & 6'd7);
    m_ncols = m_last ? 4'(m_f) + 4'd1 : 4'd4;
    for (int i = 0; i < 5; i++) begin
        logic [63:0] dd;
        logic [7:0]  cc;
        cc = '0;
        dd = (i < 4) ? m_d[64*i +: 64] : 64'd0;
        if (!m_last || i < m_f) begin
            mcol[i] = {8'h00, dd};
        end else begin
            for (int b = 0; b < 8; b++) begin
                if (b < m_j)       begin cc[b] = 1'b0; end
                else if (b == m_j) begin cc[b] = 1'b1; dd[8*b +: 8] = XG_TERM; end
                else               begin cc[b] = 1'b1; dd[8*b +: 8] = XG_IDLE; end
            end
            mcol[i] = {cc, dd};
        end
    end
end

// what to append this cycle
logic [71:0] app [8];
logic [3:0]  napp;
logic [1:0]  k_idle;
logic [6:0]  gmin;
logic        a_start, a_end, a_err_end, a_under, a_abort;
kst_t        kst_n;

always_comb begin
    gmin    = 7'(12 - DIC_MAX) + 7'(dic);
    k_idle  = (gap >= gmin) ? 2'd0 : 2'((gmin - gap + 7'd7) >> 3);
    for (int i = 0; i < 8; i++) app[i] = COL_IDLE;
    napp      = '0;
    pk_take   = 1'b0;
    a_start   = 1'b0;
    a_end     = 1'b0;
    a_err_end = 1'b0;
    a_under   = 1'b0;
    a_abort   = 1'b0;
    kst_n     = kst;
    case (kst)
        K_IDLE: if (m_v) begin
            // [idle x k] [S] [columns of the first beat] (or [S][E] for an abort)
            for (int i = 0; i < 8; i++) begin
                if (i < k_idle)                       app[i] = COL_IDLE;
                else if (i == k_idle)                 app[i] = COL_S;
                else if (m_err)                       app[i] = COL_ERR;
                else if (i - int'(k_idle) - 1 < 5)    app[i] = mcol[i - int'(k_idle) - 1];
            end
            napp = 4'(k_idle) + 4'd1 + (m_err ? 4'd1 : m_ncols);
            if (cnt + napp <= 4'd12) begin
                pk_take = 1'b1;
                a_start = 1'b1;
                if (m_err) begin
                    a_err_end = 1'b1;
                    a_abort   = 1'b1;
                    kst_n     = m_last ? K_IDLE : K_DRAIN;
                end else if (m_last) begin
                    a_end = 1'b1;
                    kst_n = K_IDLE;
                end else begin
                    kst_n = K_FRAME;
                end
            end else begin
                napp = '0;
            end
        end
        K_FRAME: begin
            if (m_v) begin
                if (m_err) begin
                    app[0] = COL_ERR;
                    napp   = 4'd1;
                end else begin
                    for (int i = 0; i < 5; i++) app[i] = mcol[i];
                    napp = m_ncols;
                end
                if (cnt + napp <= 4'd12) begin
                    pk_take = 1'b1;
                    if (m_err) begin
                        a_err_end = 1'b1;
                        a_abort   = 1'b1;
                        kst_n     = m_last ? K_IDLE : K_DRAIN;
                    end else if (m_last) begin
                        a_end = 1'b1;
                        kst_n = K_IDLE;
                    end
                end else begin
                    napp = '0;
                end
            end else if (cnt < 4'd4) begin
                // the next column of the frame is due and there is no beat
                app[0]    = COL_ERR;
                napp      = 4'd1;
                a_err_end = 1'b1;
                a_under   = 1'b1;
                kst_n     = K_DRAIN;
            end
        end
        default: begin   // K_DRAIN: discard the rest of an aborted frame
            if (m_v) begin
                pk_take = 1'b1;
                if (m_last) kst_n = K_IDLE;
            end
        end
    endcase
    if (!ce) begin
        pk_take   = 1'b0;
        napp      = '0;
        a_start   = 1'b0;
        a_end     = 1'b0;
        a_err_end = 1'b0;
        a_under   = 1'b0;
        a_abort   = 1'b0;
        kst_n     = kst;
    end
end

// the column sequence buff[0..cnt) ++ app[0..napp): four go out, the rest stays
logic [71:0] seqv [12];
logic [4:0]  total;
always_comb begin
    total = 5'(cnt) + 5'(napp);
    for (int k = 0; k < 12; k++) begin
        seqv[k] = COL_IDLE;
        if (k < 8 && k < cnt) seqv[k] = buff[k];
        else begin
            for (int a = 0; a < 8; a++) if (k == int'(cnt) + a && a < napp) seqv[k] = app[a];
        end
    end
end

function automatic logic [2:0] dic_next(input logic [2:0] d, input logic [6:0] g);
    int v;
    v = int'(d) + 12 - int'(g);
    if (v < 0) v = 0;
    if (v > DIC_MAX) v = DIC_MAX;
    return 3'(v);
endfunction

always_ff @(posedge clk) begin
    logic [2:0] fill;
    logic [6:0] g;
    ev_frame     <= 1'b0;
    ev_underflow <= 1'b0;
    ev_abort     <= 1'b0;
    if (ce) begin
        fill = (total >= 5'd4) ? 3'd0 : 3'(5'd4 - total);
        for (int c = 0; c < 4; c++) begin
            xd[64*c +: 64] <= seqv[c][63:0];
            xc[8*c +: 8]   <= seqv[c][71:64];
        end
        for (int k = 0; k < 8; k++) buff[k] <= seqv[k + 4];
        cnt <= (total >= 5'd4) ? 4'(total - 5'd4) : 4'd0;
        kst <= kst_n;
        if (a_start) dic <= dic_next(dic, 7'(int'(gap) + 8 * int'(k_idle)));
        // gap: from the /T/ (or /E/) column of this cycle, plus idle fill columns
        if (a_end)          g = 7'd8 - 7'(m_j);
        else if (a_err_end) g = 7'd8;
        else if (a_start || kst == K_FRAME) g = 7'd0;
        else                g = gap;
        g = (int'(g) + 8 * int'(fill) >= 64) ? 7'd64 : g + 7'(8 * int'(fill));
        gap <= g;
        ev_frame     <= a_end;
        ev_underflow <= a_under;
        ev_abort     <= a_abort;
    end
    if (rst) begin
        kst <= K_IDLE;
        cnt <= '0;
        gap <= 7'd64;
        dic <= '0;
        xd  <= {32{XG_IDLE}};
        xc  <= '1;
        ev_frame     <= 1'b0;
        ev_underflow <= 1'b0;
        ev_abort     <= 1'b0;
    end
end

endmodule

`resetall
