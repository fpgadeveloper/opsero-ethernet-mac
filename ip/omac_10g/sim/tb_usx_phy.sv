// SPDX-License-Identifier: MIT
//
// tb_usx_phy - behavioural model of the host side of a USXGMII multi-rate PHY
// (single port, 10.3125 Gb/s), written for the omac_10g USXGMII tests from the
// protocol description, independently of the omac RTL: its own 64B/66B encoder
// and decoder, scrambler, descrambler, CRC-32, replication, de-replication and
// auto-negotiation. Nothing of omac_pkg or the omac modules is used.
//
// Transmit (tx_clk, the PHY's clock = the DUT's recovered clock): 66-bit
// blocks (IEEE bit order as on the omac GT interface: {payload, hdr}, hdr[0]
// first). While auto-negotiation runs: configuration ordered sets (/Q/, word
// high byte, word low byte, opcode 0x03) in both halves of every block
// (txfmt = 0) or in the low half with idles above (txfmt = 1), then idles. At
// link: frames from `txq`, every 32-bit word replicated `rep` times (the /S/
// word once, its copies with 0xAA in lane 0; the /T/ word once, its copies idle
// words), idle words in between, also replicated.
// Stress knobs (per inter-frame gap, in percent): `stress` inserts 1-3 or
// deletes 1-3 single idle words (the clock compensation of a real PHY, which
// moves the next /S/ between lane 0 and lane 4 and breaks the replication
// phase of the gap), `lpi` replaces the gap's idle words by LPI words,
// `corrupt` flips one bit in one non-first copy of a data word of the frame
// (rep >= 2), `badfcs` frames carry a wrong FCS.
// Receive (rx_clk, the DUT's transmit clock; the DUT's blocks arrive aligned):
// descramble, decode, auto-negotiation receive (three consecutive equal words
// for ability / acknowledge, three idle words for idle), and at link
// de-replication with a full check of the replication rules: the /S/ word in
// lane 0 of a block at rep >= 2, the copies of every word exactly as above, the
// gap after the /T/ word a multiple of `rep` words (not checked across a speed
// change); frames are rebuilt
// (preamble, SFD, FCS checked) and stored in `rxq` with the DUT cycle of their
// /S/ block. The inter-packet gap in bytes at the link speed is measured.
//
// Auto-negotiation: clause 37 figure 37-6 style (no next page), the PHY's word
// `word` (bit 14 added in acknowledge), restart on `restart_req` (a new word:
// the whole exchange again, or with `resignal` = 1 straight from link-ok back
// to ability detect with the new word), restart when the DUT sends words again
// while at link. `inconsist` = 1: in the next exchange the acknowledged word
// carries another speed than the ability word (clause 37 consistency check),
// until the DUT restarts. `an_en` = 0: no auto-negotiation, data at `force_rep`.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1fs
`default_nettype none

module tb_usx_phy #(
    parameter int LINK_TIMER = 2000
) (
    input  wire logic        tx_clk,
    output logic      [1:0]  tx_hdr = 2'b01,
    output logic      [63:0] tx_data = '0,
    input  wire logic        rx_clk,
    input  wire logic [1:0]  rx_hdr,
    input  wire logic [63:0] rx_data,
    input  wire logic [31:0] tx_cyc,
    input  wire logic [31:0] rx_cyc
);

// ---------------- protocol constants (IEEE 802.3 clauses 46 / 49, USXGMII) ----------------
localparam byte unsigned K_IDLE = 8'h07, K_LPI = 8'h06, K_S = 8'hFB, K_T = 8'hFD, K_E = 8'hFE, K_Q = 8'h9C;
localparam byte unsigned AN_OP = 8'h03, FILL = 8'hAA;

// ---------------- knobs ----------------
bit          an_en     = 1'b1;
logic [15:0] word      = 16'h9601;     // link, full duplex, 10G, bit 0
int          force_rep = 1;
bit          txfmt     = 1'b0;
bit          resignal  = 1'b0;
bit          restart_req = 1'b0;
int          stress    = 0;
int          lpi       = 0;
int          corrupt   = 0;
int          gapmax    = 3;
bit          go        = 1'b1;          // send frames (else only idles at link)
bit          inconsist = 1'b0;          // one exchange: acknowledge with another speed than offered

// ---------------- results ----------------
int  n_ins = 0, n_del = 0, n_lpi = 0, n_corrupt = 0, n_enc_err = 0;
int  n_dec_err = 0, n_rep_viol = 0, n_fill_err = 0, n_align_err = 0, n_gap_err = 0, n_s_lane_err = 0;
int  n_an_done = 0, n_an_start = 0;
int  ipg_min = 1 << 30, ipg_sum = 0, ipg_n = 0;
logic [15:0] dut_word = '0;             // the DUT's word acknowledged at the last link-up
int  rep = 1;                           // replication in use (both directions)
bit  link = 1'b0;
int  st = 0;                            // AN state (0 enable .. 6 link ok, 7 off)

typedef struct { byte unsigned b[$]; bit badfcs; } pframe_t;
pframe_t txq [$];
int      sent_cyc [$];                  // per sent frame: tx_cyc of its /S/ block on tx_data
int      sent_lane [$];
int      sent_corrupt [$];
typedef struct { byte unsigned b[$]; bit ok; int cyc; int lane; } rframe_t;
rframe_t rxq [$];

task automatic push_tx(input byte unsigned b[$], input bit bad);
    pframe_t f;
    f.b = b; f.badfcs = bad;
    txq.push_back(f);
endtask

// ---------------- CRC-32 (bitwise, reflected 0xEDB88320) ----------------
function automatic logic [31:0] crc32(ref byte unsigned b[$]);
    logic [31:0] c;
    c = 32'hFFFF_FFFF;
    foreach (b[i]) begin
        c = c ^ 32'(b[i]);
        for (int k = 0; k < 8; k++) c = c[0] ? ((c >> 1) ^ 32'hEDB8_8320) : (c >> 1);
    end
    return ~c;
endfunction

// ---------------- 7-bit control codes ----------------
function automatic int ccode(byte unsigned ch);
    if (ch == K_IDLE) return 7'h00;
    if (ch == K_LPI)  return 7'h06;
    if (ch == K_E)    return 7'h1E;
    return -1;
endfunction

function automatic int cchar(logic [6:0] code);
    if (code == 7'h00) return K_IDLE;
    if (code == 7'h06) return K_LPI;
    if (code == 7'h1E) return K_E;
    return -1;
endfunction

// ---------------- encoder: one column (lanes 0..7) -> {payload, hdr} ----------------
function automatic logic [65:0] encode(input logic [7:0] c, input logic [63:0] d, output bit bad);
    byte unsigned L [8];
    logic [63:0] p;
    int k, cc;
    bad = 1'b0;
    for (int i = 0; i < 8; i++) L[i] = d[8*i +: 8];
    p = '0;
    if (c == 8'h00) return {d, 2'b10};
    if (c == 8'h01 && L[0] == K_S) begin
        p = {d[63:8], 8'h78};
    end else if (c == 8'hFF && L[0] != K_T) begin
        p[7:0] = 8'h1E;
        for (int i = 0; i < 8; i++) begin
            cc = ccode(L[i]); if (cc < 0) bad = 1'b1;
            p[8 + 7*i +: 7] = 7'(cc);
        end
    end else if (c == 8'h1F && L[4] == K_S) begin
        p[7:0] = 8'h33;
        for (int i = 0; i < 4; i++) begin
            cc = ccode(L[i]); if (cc < 0) bad = 1'b1;
            p[8 + 7*i +: 7] = 7'(cc);
        end
        p[63:40] = d[63:40];
    end else if (c == 8'h11 && L[0] == K_Q && L[4] == K_Q) begin
        p[7:0] = 8'h55; p[31:8] = d[31:8]; p[35:32] = 4'h0; p[39:36] = 4'h0; p[63:40] = d[63:40];
    end else if (c == 8'h11 && L[0] == K_Q && L[4] == K_S) begin
        p[7:0] = 8'h66; p[31:8] = d[31:8]; p[35:32] = 4'h0; p[63:40] = d[63:40];
    end else if (c == 8'hF1 && L[0] == K_Q) begin
        p[7:0] = 8'h4B; p[31:8] = d[31:8]; p[35:32] = 4'h0;
        for (int i = 4; i < 8; i++) begin
            cc = ccode(L[i]); if (cc < 0) bad = 1'b1;
            p[36 + 7*(i-4) +: 7] = 7'(cc);
        end
    end else if (c == 8'h1F && L[4] == K_Q) begin
        p[7:0] = 8'h2D;
        for (int i = 0; i < 4; i++) begin
            cc = ccode(L[i]); if (cc < 0) bad = 1'b1;
            p[8 + 7*i +: 7] = 7'(cc);
        end
        p[39:36] = 4'h0; p[63:40] = d[63:40];
    end else begin
        k = -1;
        for (int j = 0; j < 8; j++) if (c == (8'hFF << j) && L[j] == K_T) k = j;
        if (k < 0) begin
            bad = 1'b1;
            p[7:0] = 8'h1E;
            for (int i = 0; i < 8; i++) p[8 + 7*i +: 7] = 7'h1E;
        end else begin
            case (k)
                0: p[7:0] = 8'h87; 1: p[7:0] = 8'h99; 2: p[7:0] = 8'hAA; 3: p[7:0] = 8'hB4;
                4: p[7:0] = 8'hCC; 5: p[7:0] = 8'hD2; 6: p[7:0] = 8'hE1; default: p[7:0] = 8'hFF;
            endcase
            for (int i = 0; i < k; i++) p[8 + 8*i +: 8] = L[i];
            for (int i = k + 1; i < 8; i++) begin
                cc = ccode(L[i]); if (cc < 0) bad = 1'b1;
                p[64 - 7*(8-i) +: 7] = 7'(cc);
            end
        end
    end
    return {p, 2'b01};
endfunction

// ---------------- decoder: {payload, hdr} -> lanes; ok = 0 for an invalid block ----------------
function automatic void decode(input logic [1:0] h, input logic [63:0] p, output logic [7:0] c,
                               output logic [63:0] d, output bit ok);
    int k, ch;
    ok = 1'b1; c = '0; d = '0;
    if (h == 2'b10) begin d = p; return; end
    if (h != 2'b01) begin ok = 1'b0; return; end
    k = -1;
    case (p[7:0])
        8'h87: k = 0; 8'h99: k = 1; 8'hAA: k = 2; 8'hB4: k = 3;
        8'hCC: k = 4; 8'hD2: k = 5; 8'hE1: k = 6; 8'hFF: k = 7;
        default: k = -1;
    endcase
    if (k >= 0) begin
        c = 8'hFF << k;
        for (int i = 0; i < k; i++) d[8*i +: 8] = p[8 + 8*i +: 8];
        d[8*k +: 8] = K_T;
        for (int i = k + 1; i < 8; i++) begin
            ch = cchar(p[64 - 7*(8-i) +: 7]); if (ch < 0) ok = 1'b0;
            d[8*i +: 8] = 8'(ch);
        end
        return;
    end
    case (p[7:0])
        8'h1E: begin
            c = 8'hFF;
            for (int i = 0; i < 8; i++) begin
                ch = cchar(p[8 + 7*i +: 7]); if (ch < 0) ok = 1'b0;
                d[8*i +: 8] = 8'(ch);
            end
        end
        8'h78: begin c = 8'h01; d = {p[63:8], K_S}; end
        8'h33, 8'h2D: begin
            c = 8'h1F;
            for (int i = 0; i < 4; i++) begin
                ch = cchar(p[8 + 7*i +: 7]); if (ch < 0) ok = 1'b0;
                d[8*i +: 8] = 8'(ch);
            end
            d[39:32] = (p[7:0] == 8'h33) ? K_S : K_Q;
            if (p[7:0] == 8'h2D && p[39:36] != 4'h0) ok = 1'b0;
            d[63:40] = p[63:40];
        end
        8'h55, 8'h66: begin
            c = 8'h11;
            d[7:0] = K_Q; d[31:8] = p[31:8]; d[63:40] = p[63:40];
            d[39:32] = (p[7:0] == 8'h66) ? K_S : K_Q;
            if (p[35:32] != 4'h0 || (p[7:0] == 8'h55 && p[39:36] != 4'h0)) ok = 1'b0;
        end
        8'h4B: begin
            c = 8'hF1;
            d[7:0] = K_Q; d[31:8] = p[31:8];
            if (p[35:32] != 4'h0) ok = 1'b0;
            for (int i = 4; i < 8; i++) begin
                ch = cchar(p[36 + 7*(i-4) +: 7]); if (ch < 0) ok = 1'b0;
                d[8*i +: 8] = 8'(ch);
            end
        end
        default: ok = 1'b0;
    endcase
endfunction

// ---------------- scrambler / descrambler x^58 + x^39 + 1, bit-serial ----------------
logic [57:0] scr = '1;      // scr[0] = the most recent output bit
logic [57:0] dsc = '0;

function automatic logic [63:0] scramble(input logic [63:0] din);
    logic [63:0] o;
    for (int i = 0; i < 64; i++) begin
        o[i] = din[i] ^ scr[38] ^ scr[57];
        scr  = {scr[56:0], o[i]};
    end
    return o;
endfunction

function automatic logic [63:0] descramble(input logic [63:0] din);
    logic [63:0] o;
    for (int i = 0; i < 64; i++) begin
        o[i] = din[i] ^ dsc[38] ^ dsc[57];
        dsc  = {dsc[56:0], din[i]};
    end
    return o;
endfunction

function automatic int rep_of(logic [2:0] sp);
    case (sp)
        3'd0: return 1000; 3'd1: return 100; 3'd2: return 10;
        3'd4: return 4;    3'd5: return 2;   default: return 1;
    endcase
endfunction

// ---------------- receive side state (rx_clk), shared with the AN process ----------------
logic [15:0] hist [3];
int          nhist = 0;
int          idle_run = 0;
wire         abm  = nhist >= 3 && ((hist[0] ^ hist[1]) & 16'hBFFF) == 0 && ((hist[0] ^ hist[2]) & 16'hBFFF) == 0;
wire         ackm = nhist >= 3 && hist[0] == hist[1] && hist[0] == hist[2] && hist[0][14];
wire         idm  = idle_run >= 3;

// ---------------- auto-negotiation (tx_clk) ----------------
localparam int M_EN = 0, M_RST = 1, M_AB = 2, M_ACK = 3, M_CMP = 4, M_IDL = 5, M_OK = 6, M_OFF = 7;
int          lt = 0;
logic [15:0] ab_word = '0, tx_word = '0;
bit          ack_seen = 1'b0;

always @(posedge tx_clk) begin
    if (!an_en) begin
        st = M_OFF; rep = force_rep; link = 1'b1;
    end else begin
        if (st == M_OFF) st = M_EN;
        if (restart_req) begin
            restart_req = 1'b0;
            if (resignal && st == M_OK) st = M_AB;
            else st = M_EN;
            link = 1'b0;
        end
        case (st)
            M_EN:  begin st = M_RST; lt = LINK_TIMER; link = 1'b0; n_an_start++; ack_seen = 1'b0; end
            M_RST: begin tx_word = '0; lt--; if (lt <= 0) st = M_AB; end
            M_AB:  begin
                tx_word = word & 16'hBFFF;
                if (abm && hist[0] != 0) begin ab_word = hist[0]; st = M_ACK; end
            end
            M_ACK: begin
                tx_word = inconsist ? ((word ^ 16'h0200) | 16'h4000) : (word | 16'h4000);
                if (nhist > 0 && hist[0][14]) ack_seen = 1'b1;      // the DUT acknowledges our ability
                if (ackm) begin
                    if (((hist[0] ^ ab_word) & 16'hBFFF) == 0) begin st = M_CMP; lt = LINK_TIMER; dut_word = hist[0]; end
                    else st = M_EN;
                end else if (abm && hist[0] == 0) begin
                    st = M_EN;
                    // the DUT restarted after it had seen the inconsistent word: done
                    if (ack_seen) inconsist = 1'b0;
                end
            end
            M_CMP: begin
                tx_word = inconsist ? ((word ^ 16'h0200) | 16'h4000) : (word | 16'h4000);
                if (abm && hist[0] == 0) begin st = M_EN; if (ack_seen) inconsist = 1'b0; end
                else begin lt--; if (lt <= 0) begin st = M_IDL; lt = LINK_TIMER; end end
            end
            M_IDL: begin
                if (abm && hist[0] == 0) st = M_EN;
                else begin
                    if (lt > 0) lt--;
                    if (lt <= 0 && idm) begin
                        st = M_OK; rep = rep_of(word[11:9]); link = 1'b1; n_an_done++; inconsist = 1'b0;
                    end
                end
            end
            M_OK:  if (abm) begin st = M_EN; link = 1'b0; end
            default: st = M_EN;
        endcase
    end
end

// ---------------- transmit ----------------
typedef struct packed { logic sof; logic [3:0] c; logic [31:0] d; } wrd_t;
wrd_t wq [$];
int   gap_words = 0;            // idle words still to send before the next frame may start
int   corrupted_now = 0;
localparam logic [31:0] IDLE_W = {4{K_IDLE}};

function automatic wrd_t mk(logic [3:0] c, logic [31:0] d, logic s = 1'b0);
    wrd_t w; w.sof = s; w.c = c; w.d = d; return w;
endfunction

task automatic push_frame();
    pframe_t f;
    byte unsigned x [$];
    logic [31:0] fcs;
    wrd_t ws [$];
    int nw, cw, cr, cb, tpos;
    f = txq.pop_front();
    x = {K_S, 8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'h55, 8'hD5};
    foreach (f.b[i]) x.push_back(f.b[i]);
    fcs = crc32(f.b);
    if (f.badfcs) fcs = fcs ^ 32'h0000_0100;
    for (int i = 0; i < 4; i++) x.push_back(fcs[8*i +: 8]);
    tpos = x.size();
    x.push_back(K_T);
    while (x.size() % 4 != 0) x.push_back(K_IDLE);
    nw = x.size() / 4;
    // 32-bit words with their control flags (lane i = byte 4w+i)
    for (int w = 0; w < nw; w++) begin
        logic [3:0] c; logic [31:0] d;
        for (int i = 0; i < 4; i++) begin
            d[8*i +: 8] = x[4*w + i];
            c[i] = (4*w + i == 0) || (4*w + i >= tpos);
        end
        ws.push_back(mk(c, d));
    end
    // which copy to corrupt: a data word from word 3 on (not the /S/ and SFD words, not the
    // first data word: with strict checking the next sample becomes an error, and a frame
    // with 4 bytes or less before an error is dropped by any MAC, not delivered as bad),
    // not the last word
    cw = -1; cr = 0; cb = 0;
    if (rep >= 2 && nw > 5 && $urandom_range(99) < corrupt) begin
        cw = $urandom_range(nw - 2, 3);
        cr = $urandom_range(rep - 1, 1);
        cb = $urandom_range(31);
        n_corrupt++;
    end
    sent_corrupt.push_back(cw >= 0);
    for (int w = 0; w < nw; w++) begin
        for (int r = 0; r < rep; r++) begin
            wrd_t o;
            o = ws[w];
            o.sof = (w == 0 && r == 0);
            if (r > 0) begin
                if (w == 0) begin o.d[7:0] = FILL; o.c[0] = 1'b0; end
                else if (w == nw - 1) begin o.d = IDLE_W; o.c = 4'hF; end
                if (w == cw && r == cr) o.d[cb] = !o.d[cb];
            end
            wq.push_back(o);
        end
    end
    // the gap: 3 + 0..gapmax idle words at the link speed, then clock compensation
    gap_words = (3 + $urandom_range(gapmax)) * rep;
    if ($urandom_range(99) < stress) begin
        if ($urandom_range(1)) begin
            int k; k = $urandom_range(3, 1); gap_words += k; n_ins += k;
        end else begin
            int k; k = $urandom_range(3, 1);
            if (gap_words - k >= 2) begin gap_words -= k; n_del += k; end
        end
    end
endtask

task automatic produce();
    logic [31:0] os;
    if (an_en && st != M_OK) begin
        os = {AN_OP, tx_word[7:0], tx_word[15:8], K_Q};
        if (st == M_IDL) begin
            wq.push_back(mk(4'hF, IDLE_W)); wq.push_back(mk(4'hF, IDLE_W));
        end else if (!txfmt) begin
            wq.push_back(mk(4'h1, os)); wq.push_back(mk(4'h1, os));
        end else begin
            wq.push_back(mk(4'h1, os)); wq.push_back(mk(4'hF, IDLE_W));
        end
    end else if (gap_words > 0) begin
        bit use_lpi;
        use_lpi = (lpi > 0) && ($urandom_range(99) < lpi);
        // a run of words of one kind (keeps the number of generator calls low at rep 1000)
        for (int i = 0; i < ((gap_words < 64) ? gap_words : 64); i++) begin
            if (use_lpi) begin wq.push_back(mk(4'hF, {4{K_LPI}})); n_lpi++; end
            else wq.push_back(mk(4'hF, IDLE_W));
        end
        gap_words -= (gap_words < 64) ? gap_words : 64;
    end else if (go && txq.size() > 0) begin
        push_frame();
    end else begin
        for (int i = 0; i < 2 * rep && i < 64; i++) wq.push_back(mk(4'hF, IDLE_W));
    end
endtask

int tx_lane_sof = -1;
always @(posedge tx_clk) begin
    wrd_t a, b;
    logic [65:0] blk;
    bit bad;
    while (wq.size() < 4) produce();
    a = wq.pop_front();
    b = wq.pop_front();
    blk = encode({b.c, a.c}, {b.d, a.d}, bad);
    if (bad) n_enc_err++;
    tx_hdr  <= blk[1:0];
    tx_data <= scramble(blk[65:2]);
    // the block is on tx_data in the next cycle (tx_cyc + 1)
    if (a.sof || b.sof) begin
        sent_cyc.push_back(tx_cyc + 1);
        sent_lane.push_back(a.sof ? 0 : 4);
    end
end

// ---------------- receive ----------------
int  rk = 0;                    // copy index of the current word (0 = sample)
bit  in_fr = 1'b0, in_tgrp = 1'b0, seen_t = 1'b0;
int  rkind = 0;                 // 0 data, 1 /S/, 2 /T/
logic [31:0] rref; logic [3:0] rrefc;
byte unsigned fb [$];
bit  fbad = 1'b0;
int  f_cyc = 0, f_lane = 0;
int  words_since_t = 0;         // words from the /T/ word (inclusive) to the next /S/
int  t_idle_bytes = 0;
int  rx_blocks = 0;
int  rx_rep = 1;

task automatic rx_word(logic [3:0] c, logic [31:0] d, int lane, int cyc);
    bit is_cfg, is_idle, s, t;
    // auto-negotiation receive
    is_cfg  = (c == 4'b0001 && d[7:0] == K_Q && d[31:24] == AN_OP);
    is_idle = (c == 4'hF && d == IDLE_W);
    if (is_cfg) begin
        hist[2] = hist[1]; hist[1] = hist[0]; hist[0] = {d[15:8], d[23:16]};
        if (nhist < 3) nhist++;
        idle_run = 0;
    end else if (is_idle) begin
        idle_run++;
        if (idle_run >= 3) nhist = 0;
    end else begin
        nhist = 0; idle_run = 0;
    end
    if (!(st == M_OK || st == M_OFF) || rep != rx_rep) begin
        // not at link, or the speed has just changed: start over at the next /S/
        in_fr = 1'b0; in_tgrp = 1'b0; seen_t = 1'b0;
        rx_rep = rep;
        if (!(st == M_OK || st == M_OFF)) return;
    end
    s = c[0] && d[7:0] == K_S;
    t = 1'b0;
    for (int i = 0; i < 4; i++) if (c[i] && d[8*i +: 8] == K_T) t = 1'b1;
    if (s) begin
        if (in_fr) n_rep_viol++;                // a new frame inside a frame
        if (rep >= 2 && lane != 0) n_s_lane_err++;
        if (seen_t) begin
            int g;
            if (words_since_t % rep != 0) n_align_err++;
            g = t_idle_bytes + 1 + 4 * ((words_since_t - rep) / rep);   // from /T/ inclusive
            if (g < ipg_min) ipg_min = g;
            ipg_sum += g; ipg_n++;
        end
        in_fr = 1'b1; in_tgrp = 1'b0; rk = 1; rkind = 1; rref = d; rrefc = c;
        fb.delete(); fbad = 1'b0; f_cyc = cyc; f_lane = lane;
        if (d[31:8] != 24'h555555 || c != 4'b0001) fbad = 1'b1;
        if (rep == 1) rk = 0;
        return;
    end
    if (in_fr || in_tgrp) begin
        if (rk == 0) begin
            // a sample
            if (in_tgrp) begin
                in_tgrp = 1'b0;                 // the gap: count words
            end else begin
                rref = d; rrefc = c; rkind = t ? 2 : 0;
                if (!t && c != 4'h0) begin
                    // an error (or any control character but /T/) ends the frame as bad
                    rframe_t r;
                    r.b = fb; r.ok = 1'b0; r.cyc = f_cyc; r.lane = f_lane;
                    rxq.push_back(r);
                    in_fr = 1'b0; seen_t = 1'b0;
                    return;
                end
                for (int i = 0; i < 4; i++) begin
                    if (c[i] && d[8*i +: 8] == K_T) begin
                        t = 1'b1;
                        break;
                    end
                    if (c[i]) fbad = 1'b1;
                    fb.push_back(d[8*i +: 8]);
                end
                if (t) begin
                    // end of frame: preamble (7 x 0x55 after /S/ + SFD) and FCS
                    rframe_t r;
                    int n;
                    bit ok;
                    t_idle_bytes = 0;
                    for (int i = 3; i >= 0; i--) begin if (c[i] && d[8*i +: 8] == K_IDLE) t_idle_bytes++; else break; end
                    n = fb.size();
                    ok = !fbad && n >= 4 + 4 + 4;
                    if (ok) ok = fb[0] == 8'h55 && fb[1] == 8'h55 && fb[2] == 8'h55 && fb[3] == 8'hD5;
                    r.b = fb[4:$];
                    if (ok) begin
                        byte unsigned pl [$];
                        logic [31:0] f;
                        pl = r.b[0:$-4];
                        f = crc32(pl);
                        ok = (f == {r.b[$], r.b[$-1], r.b[$-2], r.b[$-3]});
                        r.b = pl;
                    end
                    r.ok = ok; r.cyc = f_cyc; r.lane = f_lane;
                    rxq.push_back(r);
                    in_fr = 1'b0; in_tgrp = (rep >= 2); seen_t = 1'b1; words_since_t = 0;
                end
            end
        end else begin
            // a copy: check it against the rules
            case (rkind)
                1: begin
                    if (c != {rrefc[3:1], 1'b0} || d[31:8] != rref[31:8]) n_rep_viol++;
                    if (d[7:0] != FILL) n_fill_err++;
                end
                2: if (c != 4'hF || d != IDLE_W) n_rep_viol++;
                default: if (c != rrefc || d != rref) n_rep_viol++;
            endcase
        end
        if (rep >= 2) rk = (rk + 1) % rep;
    end
    if (seen_t && !in_fr) begin
        // between frames only control words: idles (LPI) or ordered sets
        if (words_since_t > 0 && c != 4'hF && !(c == 4'h1 && d[7:0] == K_Q)) n_gap_err++;
        words_since_t++;
    end
endtask

always @(posedge rx_clk) begin
    logic [7:0]  c;
    logic [63:0] d;
    bit ok;
    decode(rx_hdr, descramble(rx_data), c, d, ok);
    rx_blocks++;
    if (rx_blocks > 2) begin
        if (!ok) n_dec_err++;
        rx_word(c[3:0], d[31:0], 0, rx_cyc);
        rx_word(c[7:4], d[63:32], 4, rx_cyc);
    end
end

endmodule
