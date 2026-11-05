// SPDX-License-Identifier: MIT
//
// tb_pcs_units - self-checking test of the 64B/66B building blocks:
//   1. interop vectors: XGMII columns encoded by omac_pkg::enc66 against 66-bit
//      blocks written down by hand from IEEE 802.3 figure 49-7 (block type
//      fields, field positions, right-aligned control codes), and the first
//      scrambled block from a zero scrambler state computed by hand from
//      x^58 + x^39 + 1 (idle block 0x1E -> 0x78000F000000001E);
//   2. encode -> decode round trip of random columns of every block format
//      (and invalid columns -> error block / error column);
//   3. omac_scrambler against a bit-serial LFSR model, and omac_descrambler
//      undoing it from a different initial state after one block.
// Prints TB_PASS or TB_FAIL <n>.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_pcs_units;

import omac_pkg::*;

int errors = 0;

task automatic check66(string name, logic [63:0] d, logic [7:0] c, logic [1:0] hdr, logic [63:0] pay);
    logic [65:0] b;
    b = enc66(d, c);
    if (b[1:0] !== hdr || b[65:2] !== pay) begin
        $display("TB_ERR vector %s: got hdr=%b pay=%016x, want hdr=%b pay=%016x", name, b[1:0], b[65:2], hdr, pay);
        errors++;
    end
endtask

// ---------- random column of a given format ----------
function automatic logic [71:0] rnd_col(int fmt);
    logic [63:0] d;
    logic [7:0]  c;
    logic [7:0]  codes [3];
    logic [7:0]  oset  [2];
    codes = '{XG_IDLE, XG_LPI, XG_IDLE};
    oset  = '{XG_SEQ, XG_SIG};
    d = {$urandom, $urandom};
    c = '0;
    case (fmt)
        0: c = 8'h00;                                                     // data
        1: begin c = 8'hFF; for (int i = 0; i < 8; i++) d[8*i +: 8] = codes[$urandom_range(2)]; end
        2: begin c = 8'h01; d[7:0] = XG_START; end                         // S0
        3: begin c = 8'h1F; for (int i = 0; i < 4; i++) d[8*i +: 8] = codes[$urandom_range(2)]; d[39:32] = XG_START; end
        4: begin c = 8'h1F; for (int i = 0; i < 4; i++) d[8*i +: 8] = codes[$urandom_range(2)]; d[39:32] = oset[$urandom_range(1)]; end
        5: begin c = 8'h11; d[7:0] = oset[$urandom_range(1)]; d[39:32] = XG_START; end
        6: begin c = 8'h11; d[7:0] = oset[$urandom_range(1)]; d[39:32] = oset[$urandom_range(1)]; end
        7: begin c = 8'hF1; d[7:0] = oset[$urandom_range(1)]; for (int i = 4; i < 8; i++) d[8*i +: 8] = codes[$urandom_range(2)]; end
        default: begin                                                     // T at lane k
            int k;
            k = fmt - 8;
            c = 8'hFF << k;
            d[8*k +: 8] = XG_TERM;
            for (int i = k + 1; i < 8; i++) d[8*i +: 8] = codes[$urandom_range(2)];
        end
    endcase
    return {c, d};
endfunction

// bit-serial scrambler model: out = in ^ s[38] ^ s[57], s[0] = last output bit
function automatic logic [63:0] ser_scr(ref logic [57:0] s, input logic [63:0] din);
    logic [63:0] o;
    for (int i = 0; i < 64; i++) begin
        o[i] = din[i] ^ s[38] ^ s[57];
        s = {s[56:0], o[i]};
    end
    return o;
endfunction

logic clk = 1'b0;
always #1 clk = ~clk;
logic        s_rst = 1'b1, s_en = 1'b0;
logic [63:0] s_in = '0;
wire  [63:0] s_out, d_out;
localparam logic [57:0] SINIT = 58'h2A5_A5C3_3C96_0FF1;
omac_scrambler #(.INIT(SINIT)) u_scr0 (.clk(clk), .rst(s_rst), .en(s_en), .din(s_in), .dout(s_out));
omac_descrambler u_dsc (.clk(clk), .en(s_en), .din(s_out), .dout(d_out));

initial begin
    logic [71:0] cd;
    logic [65:0] b;
    logic [74:0] x;
    logic [57:0] ss;
    logic [63:0] words [$];
    logic [63:0] exp_s [$];
    int nrt;
    // ---------------- 1. interop vectors (figure 49-7, by hand) ----------------
    check66("idle",   {8{XG_IDLE}}, 8'hFF, 2'b01, 64'h0000_0000_0000_001E);
    check66("S0",     64'hD555_5555_5555_55FB, 8'h01, 2'b01, 64'hD555_5555_5555_5578);
    check66("data",   64'h0123_4567_89AB_CDEF, 8'h00, 2'b10, 64'h0123_4567_89AB_CDEF);
    check66("T0",     {{7{XG_IDLE}}, XG_TERM}, 8'hFF, 2'b01, 64'h0000_0000_0000_0087);
    check66("T3",     {{4{XG_IDLE}}, XG_TERM, 24'h33_22_11}, 8'hF8, 2'b01, 64'h0000_0000_3322_11B4);
    check66("T7",     64'hFD07_0605_0403_0201, 8'h80, 2'b01, 64'h0706_0504_0302_01FF);
    check66("S4",     64'h5555_55FB_0707_0707, 8'h1F, 2'b01, 64'h5555_5500_0000_0033);
    check66("LF",     64'h0100_009C_0100_009C, 8'h11, 2'b01, 64'h0100_0000_0100_0055);
    check66("LF+I",   64'h0707_0707_0100_009C, 8'hF1, 2'b01, 64'h0000_0000_0100_004B);
    check66("err",    {8{XG_ERROR}}, 8'hFF, 2'b01, 64'h3C78_F1E3_C78F_1E1E);
    check66("bad",    64'h0707_0707_0707_0755, 8'hFF, 2'b01, 64'h3C78_F1E3_C78F_1E1E);
    check66("T_mid",  64'h0707_FD07_0707_0707, 8'hFF, 2'b01, 64'h3C78_F1E3_C78F_1E1E);
    // first scrambled block from state 0: hand computation in the header
    ss = '0;
    if (ser_scr(ss, 64'h1E) !== 64'h7800_0F00_0000_001E) begin
        $display("TB_ERR serial scrambler model vector"); errors++;
    end
    // ---------------- 2. round trip ----------------
    nrt = 0;
    for (int n = 0; n < 4000; n++) begin
        int fmt;
        rtype_t want;
        fmt = $urandom_range(15);
        cd = rnd_col(fmt);
        b = enc66(cd[63:0], cd[71:64]);
        x = dec66(b[1:0], b[65:2]);
        want = (fmt == 0) ? RT_D : (fmt == 2 || fmt == 3 || fmt == 5) ? RT_S : (fmt >= 8) ? RT_T : RT_C;
        if (x[71:0] !== cd || rtype_t'(x[74:72]) != want) begin
            $display("TB_ERR roundtrip fmt %0d col %018x -> %017x -> %019x", fmt, cd, b, x);
            errors++;
        end
        nrt++;
    end
    // invalid blocks decode as errors
    x = dec66(2'b00, 64'h0);
    if (rtype_t'(x[74:72]) != RT_E || x[71:64] != 8'hFF || x[63:0] != {8{XG_ERROR}}) begin
        $display("TB_ERR invalid header not RT_E"); errors++;
    end
    x = dec66(2'b01, 64'h0000_0000_0000_0042);
    if (rtype_t'(x[74:72]) != RT_E) begin $display("TB_ERR invalid type not RT_E"); errors++; end
    x = dec66(2'b01, {56'h7F, 8'h1E});   // invalid 7-bit code
    if (rtype_t'(x[74:72]) != RT_E) begin $display("TB_ERR invalid code not RT_E"); errors++; end
    // ---------------- 3. scrambler / descrambler ----------------
    // the scrambler starts from SINIT, the descrambler from 0 (self-synchronising);
    // the serial model's s[0] is the most recent bit, the RTL's state[57]
    for (int i = 0; i < 58; i++) ss[i] = SINIT[57 - i];
    for (int n = 0; n < 300; n++) begin
        words.push_back({$urandom, $urandom});
        exp_s.push_back(ser_scr(ss, words[n]));
    end
    @(posedge clk); s_rst <= 1'b0;
    for (int n = 0; n < 300; n++) begin
        @(posedge clk);
        s_en <= 1'b1;
        s_in <= words[n];
        // s_in is sampled one edge after it is driven: scrambler output lags 2
        // iterations, the descrambler 3 (and needs one block to synchronise)
        if (n >= 2 && s_out !== exp_s[n-2]) begin
            $display("TB_ERR scrambler word %0d %016x want %016x", n - 2, s_out, exp_s[n-2]); errors++;
        end
        if (n >= 4 && d_out !== words[n-3]) begin
            $display("TB_ERR descrambler word %0d %016x want %016x", n - 3, d_out, words[n-3]); errors++;
        end
    end
    $display("TB_INFO vectors=12 roundtrip=%0d scrambled=300", nrt);
    if (errors == 0) $display("TB_PASS");
    else $display("TB_FAIL %0d", errors);
    $finish;
end

endmodule
