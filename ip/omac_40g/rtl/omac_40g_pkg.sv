// SPDX-License-Identifier: MIT
//
// omac_40g_pkg - constants and pure functions of the 40GBASE-R PCS (IEEE 802.3
// clause 82) and the 256-bit datapath of omac_40g:
//   * alignment markers (AM, table 82-3, 40GBASE-R): one 66-bit control
//     block per PCS lane every AM_PERIOD blocks, payload bytes in transmission
//     order M0 M1 M2 BIP3 M4 M5 M6 BIP7 with M4..M6 = ~M0..~M2 and BIP7 = ~BIP3;
//     AMs are not scrambled
//   * BIP3 (table 82-4): even parity over the 66-bit blocks of a lane
//     from (and including) the previous AM up to (not including) this one.
//     Table 82-4 assigns to BIP3 bit i the block bits 2+i, 10+i, ... (bit i of
//     every payload byte), and in addition sync header bit 0 to BIP3 bit 3 and
//     sync header bit 1 to BIP3 bit 4. An AM's own contribution is therefore
//     always 0x08 (its bytes cancel in pairs, header 10).
//   * clause 82 uses a subset of the clause 49 block formats: 0x1E, 0x78, 0x4B
//     and the eight /T/ types; 0x2D, 0x33, 0x66 and 0x55 are invalid (/S/ and
//     ordered sets only in lane 0 of an 8-byte column)
//   * CRC-32 helpers for 32-byte beats: the zero-state CRC of 32 bytes (a pure
//     XOR network) and the identities the MAC uses to compute the CRC of any
//     byte segment [a, b) of a beat with one fixed network:
//       crc(s, d[0..n)) = Z(d ^ s) for n >= 4 (s XORed into bytes 0..3)
//       Z(zeros ++ x)   = Z(x)        (leading zeros do not change a zero state)
//       crc(s, d[0..n)) = Z(d ^ s[0..n)) ^ (s >> 8n) for n < 4
//
// Bit order as in omac_pkg: a 66-bit block is {payload[63:0], hdr[1:0]}, hdr[0]
// first on the wire, payload byte i = payload[8*i +: 8].
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

package omac_40g_pkg;

import omac_pkg::*;

// {M2, M1, M0} of PCS lanes 0..3 (IEEE 802.3 table 82-3, 40GBASE-R)
localparam logic [3:0][23:0] AM_M = {24'h3D79A2, 24'h9B65C5, 24'hE6C4F0, 24'h477690};

// the AM block of PCS lane `lane` with BIP3 = bip3
function automatic logic [65:0] am_block(input logic [1:0] lane, input logic [7:0] bip3);
    logic [23:0] m;
    m = AM_M[lane];
    return {~bip3, ~m, bip3, m, SH_CTRL};
endfunction

// {is_am, lane}: the block is the AM of some PCS lane (M0..M2 and M4..M6 compared,
// the BIP fields ignored)
function automatic logic [2:0] am_match(input logic [65:0] b);
    logic [2:0] r;
    r = 3'b000;
    for (int l = 0; l < 4; l++) begin
        if (b[1:0] == SH_CTRL && b[25:2] == AM_M[l] && b[57:34] == ~AM_M[l]) r = {1'b1, 2'(l)};
    end
    return r;
endfunction

// BIP3 contribution of one 66-bit block (table 82-4)
function automatic logic [7:0] bip8(input logic [65:0] b);
    logic [7:0] x;
    x = '0;
    for (int i = 0; i < 8; i++) x = x ^ b[2 + 8*i +: 8];
    x[3] = x[3] ^ b[0];
    x[4] = x[4] ^ b[1];
    return x;
endfunction

// 64B/66B encode with the clause 82 subset: columns that would need a block type
// outside it become the error block
function automatic logic [65:0] enc66_r4(input logic [63:0] d, input logic [7:0] c);
    logic [65:0] b;
    b = enc66(d, c);
    if (b[1:0] == SH_CTRL && (b[9:2] == BT_CO || b[9:2] == BT_CS || b[9:2] == BT_OS || b[9:2] == BT_OO))
        b = EBLOCK;
    return b;
endfunction

// decode with the clause 82 subset ({rtype, c, d} as omac_pkg::dec66)
function automatic logic [74:0] dec66_r4(input logic [1:0] hdr, input logic [63:0] p);
    if (hdr == SH_CTRL && (p[7:0] == BT_CO || p[7:0] == BT_CS || p[7:0] == BT_OS || p[7:0] == BT_OO))
        return {RT_E, 8'hFF, {8{XG_ERROR}}};
    return dec66(hdr, p);
endfunction

// zero-state CRC-32 register after the 32 bytes of x (byte 0 first)
function automatic logic [31:0] crc_z32(input logic [255:0] x);
    logic [31:0] c;
    c = '0;
    for (int i = 0; i < 32; i++) c = crc32_byte(c, x[8*i +: 8]);
    return c;
endfunction

// byte mask: bytes [a, b) of a 32-byte beat (a in 0..32, b in 0..32)
function automatic logic [255:0] byte_mask(input logic [5:0] a, input logic [5:0] b);
    logic [255:0] m;
    for (int i = 0; i < 32; i++) m[8*i +: 8] = (i >= a && i < b) ? 8'hFF : 8'h00;
    return m;
endfunction

endpackage

`resetall
