// SPDX-License-Identifier: MIT
//
// omac_pkg - constants and pure functions shared by the omac IPs:
//   * XGMII control characters (IEEE 802.3 clause 46)
//   * 64B/66B sync headers, block types, 7-bit control codes and the encoder /
//     decoder of one 64-bit column <-> one 66-bit block (clause 49, figure 49-7)
//   * the self-synchronising scrambler x^58 + x^39 + 1 (clause 49.2.6), parallel
//   * the Ethernet CRC-32 (reflected, polynomial 0x04C11DB7 / 0xEDB88320)
//
// Bit order everywhere: bit 0 is first on the wire. A 66-bit block is
// {payload[63:0], hdr[1:0]}: hdr[0] is transmitted first, then payload[0].
// XGMII 64-bit column: d[8*i +: 8] / c[i] = lane i (lane 0 first on the wire).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

package omac_pkg;

// ---------------- XGMII control characters ----------------
localparam logic [7:0] XG_IDLE  = 8'h07;
localparam logic [7:0] XG_LPI   = 8'h06;
localparam logic [7:0] XG_START = 8'hFB;
localparam logic [7:0] XG_TERM  = 8'hFD;
localparam logic [7:0] XG_ERROR = 8'hFE;
localparam logic [7:0] XG_SEQ   = 8'h9C;   // sequence ordered set (link fault signalling)
localparam logic [7:0] XG_SIG   = 8'h5C;   // signal ordered set (reserved)
localparam logic [7:0] ETH_PRE  = 8'h55;
localparam logic [7:0] ETH_SFD  = 8'hD5;

// link fault sequence ordered sets: lane 0 = /Q/ (0x9C), lanes 1..3 = 0x00 0x00 code
localparam logic [7:0] LF_CODE  = 8'h01;   // local fault
localparam logic [7:0] RF_CODE  = 8'h02;   // remote fault

// ---------------- 64B/66B ----------------
localparam logic [1:0] SH_DATA = 2'b10;    // bits 0,1 = 0,1
localparam logic [1:0] SH_CTRL = 2'b01;    // bits 0,1 = 1,0

localparam logic [7:0] BT_CCCC = 8'h1E;    // C0..C7
localparam logic [7:0] BT_CO   = 8'h2D;    // C0..C3, O4, D5..D7
localparam logic [7:0] BT_CS   = 8'h33;    // C0..C3, S4, D5..D7
localparam logic [7:0] BT_OS   = 8'h66;    // O0, D1..D3, S4, D5..D7
localparam logic [7:0] BT_OO   = 8'h55;    // O0, D1..D3, O4, D5..D7
localparam logic [7:0] BT_S0   = 8'h78;    // S0, D1..D7
localparam logic [7:0] BT_OC   = 8'h4B;    // O0, D1..D3, C4..C7
localparam logic [7:0] BT_T0   = 8'h87;    // T0, C1..C7
localparam logic [7:0] BT_T1   = 8'h99;
localparam logic [7:0] BT_T2   = 8'hAA;
localparam logic [7:0] BT_T3   = 8'hB4;
localparam logic [7:0] BT_T4   = 8'hCC;
localparam logic [7:0] BT_T5   = 8'hD2;
localparam logic [7:0] BT_T6   = 8'hE1;
localparam logic [7:0] BT_T7   = 8'hFF;    // D0..D6, T7

localparam logic [6:0] CC_IDLE  = 7'h00;
localparam logic [6:0] CC_LPI   = 7'h06;
localparam logic [6:0] CC_ERROR = 7'h1E;
localparam logic [3:0] OC_SEQ   = 4'h0;
localparam logic [3:0] OC_SIG   = 4'hF;

// receive block classes (clause 49.2.13.2.3 R_TYPE)
typedef enum logic [2:0] { RT_C = 3'd0, RT_S = 3'd1, RT_T = 3'd2, RT_D = 3'd3, RT_E = 3'd4 } rtype_t;

function automatic logic [7:0] t_type(input int k);
    case (k)
        0: return BT_T0;  1: return BT_T1;  2: return BT_T2;  3: return BT_T3;
        4: return BT_T4;  5: return BT_T5;  6: return BT_T6;  default: return BT_T7;
    endcase
endfunction

// XGMII control character -> 7-bit control code; ok = encodable as a code
function automatic logic [7:0] cc_enc(input logic [7:0] ch);   // {ok, code}
    case (ch)
        XG_IDLE:  return {1'b1, CC_IDLE};
        XG_LPI:   return {1'b1, CC_LPI};
        XG_ERROR: return {1'b1, CC_ERROR};
        default:  return {1'b0, CC_ERROR};
    endcase
endfunction

function automatic logic [8:0] cc_dec(input logic [6:0] code);  // {ok, char}
    case (code)
        CC_IDLE:  return {1'b1, XG_IDLE};
        CC_LPI:   return {1'b1, XG_LPI};
        CC_ERROR: return {1'b1, XG_ERROR};   // valid code, but an error
        default:  return {1'b0, XG_ERROR};
    endcase
endfunction

function automatic logic is_o(input logic [7:0] ch);
    return ch == XG_SEQ || ch == XG_SIG;
endfunction

function automatic logic [3:0] o_enc(input logic [7:0] ch);
    return (ch == XG_SIG) ? OC_SIG : OC_SEQ;
endfunction

// The error block (EBLOCK_T): control block, type 0x1E, eight /E/ codes.
localparam logic [65:0] EBLOCK = {{8{CC_ERROR}}, BT_CCCC, SH_CTRL};

// Encode one XGMII column into a 66-bit block {payload, hdr}. Columns that no
// block format of figure 49-7 can carry become the error block.
function automatic logic [65:0] enc66(input logic [63:0] d, input logic [7:0] c);
    logic [7:0]  ch [8];
    logic [6:0]  cc [8];
    logic [7:0]  cok;
    logic [63:0] p;
    logic        ok;
    logic [7:0]  e;
    for (int i = 0; i < 8; i++) begin
        ch[i]  = d[8*i +: 8];
        e      = cc_enc(ch[i]);
        cok[i] = e[7];
        cc[i]  = e[6:0];
    end
    p  = '0;
    ok = 1'b1;
    if (c == 8'h00) begin
        return {d, SH_DATA};
    end else if (c == 8'h01 && ch[0] == XG_START) begin
        p = {d[63:8], BT_S0};
    end else if (c == 8'hFF && ch[0] != XG_TERM) begin
        ok = &cok;
        for (int i = 0; i < 8; i++) p[8 + 7*i +: 7] = cc[i];
        p[7:0] = BT_CCCC;
    end else if (c == 8'h1F && ch[4] == XG_START) begin
        ok = &cok[3:0];
        for (int i = 0; i < 4; i++) p[8 + 7*i +: 7] = cc[i];
        p[63:40] = d[63:40];
        p[7:0] = BT_CS;
    end else if (c == 8'h1F && is_o(ch[4])) begin
        ok = &cok[3:0];
        for (int i = 0; i < 4; i++) p[8 + 7*i +: 7] = cc[i];
        p[39:36] = o_enc(ch[4]);
        p[63:40] = d[63:40];
        p[7:0] = BT_CO;
    end else if (c == 8'h11 && is_o(ch[0]) && ch[4] == XG_START) begin
        p[31:8]  = d[31:8];
        p[35:32] = o_enc(ch[0]);
        p[63:40] = d[63:40];
        p[7:0]   = BT_OS;
    end else if (c == 8'h11 && is_o(ch[0]) && is_o(ch[4])) begin
        p[31:8]  = d[31:8];
        p[35:32] = o_enc(ch[0]);
        p[39:36] = o_enc(ch[4]);
        p[63:40] = d[63:40];
        p[7:0]   = BT_OO;
    end else if (c == 8'hF1 && is_o(ch[0])) begin
        ok = &cok[7:4];
        p[31:8]  = d[31:8];
        p[35:32] = o_enc(ch[0]);
        for (int i = 4; i < 8; i++) p[36 + 7*(i-4) +: 7] = cc[i];
        p[7:0]   = BT_OC;
    end else begin
        // terminate: lanes 0..k-1 data, lane k /T/, lanes k+1..7 control codes
        // (right-aligned at the end of the block, unused bits 0)
        ok = 1'b0;
        for (int k = 0; k < 8; k++) begin
            if (c == (8'hFF << k) && ch[k] == XG_TERM) begin
                ok = 1'b1;
                p = '0;
                for (int i = 0; i < k; i++) p[8 + 8*i +: 8] = ch[i];
                for (int i = k + 1; i < 8; i++) begin
                    ok = ok & cok[i];
                    p[64 - 7*(8-i) +: 7] = cc[i];
                end
                p[7:0] = t_type(k);
            end
        end
    end
    return ok ? {p, SH_CTRL} : EBLOCK;
endfunction

// Decode one 66-bit block into an XGMII column {rtype, c[7:0], d[63:0]}.
// Invalid blocks decode to the error column (all lanes /E/) with RT_E.
function automatic logic [74:0] dec66(input logic [1:0] hdr, input logic [63:0] p);
    logic [63:0] d;
    logic [7:0]  c;
    logic        ok;
    rtype_t      rt;
    logic [7:0]  bt;
    logic [8:0]  r;
    bt = p[7:0];
    d  = '0;
    c  = '0;
    ok = 1'b1;
    rt = RT_C;
    if (hdr == SH_DATA) begin
        return {RT_D, 8'h00, p};
    end else if (hdr != SH_CTRL) begin
        ok = 1'b0;
    end else begin
        case (bt)
            BT_CCCC: begin
                c = 8'hFF;
                for (int i = 0; i < 8; i++) begin
                    r = cc_dec(p[8 + 7*i +: 7]);
                    ok = ok & r[8] & (r[7:0] != XG_ERROR);
                    d[8*i +: 8] = r[7:0];
                end
                rt = RT_C;
            end
            BT_CO, BT_CS: begin
                c = 8'h1F;
                for (int i = 0; i < 4; i++) begin
                    r = cc_dec(p[8 + 7*i +: 7]);
                    ok = ok & r[8] & (r[7:0] != XG_ERROR);
                    d[8*i +: 8] = r[7:0];
                end
                if (bt == BT_CS) begin
                    d[39:32] = XG_START;
                    rt = RT_S;
                end else begin
                    ok = ok & (p[39:36] == OC_SEQ || p[39:36] == OC_SIG);
                    d[39:32] = (p[39:36] == OC_SIG) ? XG_SIG : XG_SEQ;
                    rt = RT_C;
                end
                d[63:40] = p[63:40];
            end
            BT_OS, BT_OO: begin
                c = 8'h11;
                ok = (p[35:32] == OC_SEQ || p[35:32] == OC_SIG);
                d[7:0]   = (p[35:32] == OC_SIG) ? XG_SIG : XG_SEQ;
                d[31:8]  = p[31:8];
                d[63:40] = p[63:40];
                if (bt == BT_OS) begin
                    d[39:32] = XG_START;
                    rt = RT_S;
                end else begin
                    ok = ok & (p[39:36] == OC_SEQ || p[39:36] == OC_SIG);
                    d[39:32] = (p[39:36] == OC_SIG) ? XG_SIG : XG_SEQ;
                    rt = RT_C;
                end
            end
            BT_S0: begin
                c = 8'h01;
                d = {p[63:8], XG_START};
                rt = RT_S;
            end
            BT_OC: begin
                c = 8'hF1;
                ok = (p[35:32] == OC_SEQ || p[35:32] == OC_SIG);
                d[7:0]  = (p[35:32] == OC_SIG) ? XG_SIG : XG_SEQ;
                d[31:8] = p[31:8];
                for (int i = 4; i < 8; i++) begin
                    r = cc_dec(p[36 + 7*(i-4) +: 7]);
                    ok = ok & r[8] & (r[7:0] != XG_ERROR);
                    d[8*i +: 8] = r[7:0];
                end
                rt = RT_C;
            end
            BT_T0, BT_T1, BT_T2, BT_T3, BT_T4, BT_T5, BT_T6, BT_T7: begin
                rt = RT_T;
                for (int k = 0; k < 8; k++) begin
                    if (bt == t_type(k)) begin
                        c = 8'hFF << k;
                        for (int i = 0; i < k; i++) d[8*i +: 8] = p[8 + 8*i +: 8];
                        d[8*k +: 8] = XG_TERM;
                        for (int i = k + 1; i < 8; i++) begin
                            r = cc_dec(p[64 - 7*(8-i) +: 7]);
                            ok = ok & r[8] & (r[7:0] != XG_ERROR);
                            d[8*i +: 8] = r[7:0];
                        end
                    end
                end
            end
            default: ok = 1'b0;
        endcase
    end
    if (!ok) return {RT_E, 8'hFF, {8{XG_ERROR}}};
    return {rt, c, d};
endfunction

// ---------------- scrambler x^58 + x^39 + 1 ----------------
// state[57] = the most recent scrambled bit. Returns {state', out}.
function automatic logic [121:0] scramble(input logic [57:0] state, input logic [63:0] din);
    logic [121:0] x;   // x[0..57] = history (oldest first), x[58+i] = out[i]
    x = {64'd0, state};
    for (int i = 0; i < 64; i++) x[58 + i] = din[i] ^ x[i + 19] ^ x[i];
    return {x[121:64], x[121:58]};
endfunction

// descrambler: history = received (scrambled) bits. Returns {state', out}.
function automatic logic [121:0] descramble(input logic [57:0] state, input logic [63:0] din);
    logic [121:0] x;
    logic [63:0]  o;
    x = {din, state};
    for (int i = 0; i < 64; i++) o[i] = din[i] ^ x[i + 19] ^ x[i];
    return {x[121:64], o};
endfunction

// ---------------- CRC-32 (Ethernet FCS) ----------------
localparam logic [31:0] CRC_INIT    = 32'hFFFF_FFFF;
localparam logic [31:0] CRC_RESIDUE = 32'hDEBB_20E3;  // register after data + FCS

function automatic logic [31:0] crc32_byte(input logic [31:0] crc_in, input logic [7:0] d);
    logic [31:0] crc;
    crc = crc_in;
    for (int i = 0; i < 8; i++) crc = (crc >> 1) ^ ((crc[0] ^ d[i]) ? 32'hEDB8_8320 : 32'h0);
    return crc;
endfunction

endpackage

`resetall
