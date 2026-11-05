// SPDX-License-Identifier: MIT
//
// tb_40g_units - self-checking unit test of the 40GBASE-R building blocks:
//   1. alignment marker interop vectors: omac_40g_pkg::am_block for PCS lanes 0-3
//      against 66-bit blocks written down by hand from IEEE 802.3 table 82-3
//      (M0 M1 M2 BIP3 M4 M5 M6 BIP7, M4..M6 = ~M0..~M2, BIP7 = ~BIP3, sync header
//      10), and bip8 against BIP3 values worked out by hand from table 82-4
//   2. omac_40g_pcs_tx with the scrambler off (SCRAMBLE = 0): idle columns in,
//      every 16384th cycle the four markers out on all lanes at once; the BIP3
//      of the second marker is hand-computed: previous marker 0x08, 16383 idle
//      blocks 0x16 each (odd count) -> 0x08 ^ 0x16 = 0x1E, so lane 0 must send
//      0xE1B8896F1E477690 (header 10); then data columns of byte 0x01 (block BIP
//      0x11) -> 0x08 ^ 0x11 = 0x19 (0xE6B8896F19477690)
//   3. pcs_tx `ce`: a counter pattern advanced only while ce = 1 comes out as a
//      gap-free block sequence around the marker cycles (no block lost or doubled)
//   4. four omac_40g_lane_rx on the scrambled pcs_tx lanes, permuted: AM lock,
//      lane numbers, no BIP error over 3 periods; one payload bit flip on one
//      lane -> exactly one BIP error on that lane; one corrupted marker -> lock
//      kept; four corrupted markers in a row -> lock lost, then regained
//   5. the CRC-32 identities of the 256-bit MAC (omac_40g_pkg) against a byte-
//      serial reference: TX last beat (right-aligned with the state XORed in, the
//      < 4-byte correction), RX first beat (masked leading bytes, initial value at
//      the first data byte), residue of frame + FCS, 3000 random cases
// Prints TB_PASS or TB_FAIL <n>.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_40g_units;

import omac_pkg::*;
import omac_40g_pkg::*;

int errors = 0;

task automatic chk(string what, logic [65:0] got, logic [65:0] want);
    if (got !== want) begin
        $display("TB_ERR %s: got %017x want %017x", what, got, want);
        errors++;
    end
endtask

logic clk = 1'b0;
always #1 clk = ~clk;

// ---------------- pcs_tx, scrambler off ----------------
logic         t_rst = 1'b1;
logic [255:0] t_xd;
logic [31:0]  t_xc;
wire          t_ce;
wire  [7:0]   t_hdr;
wire  [255:0] t_dat;
omac_40g_pcs_tx #(.AM_PERIOD(16384), .SCRAMBLE(1'b0)) u_tx0 (
    .clk(clk), .rst(t_rst), .ce(t_ce), .xd(t_xd), .xc(t_xc), .gt_tx_hdr(t_hdr), .gt_tx_data(t_dat));

// ---------------- pcs_tx, scrambled, into four lane receivers ----------------
logic         s_rst = 1'b1;
logic [255:0] s_xd;
logic [31:0]  s_xc;
wire          s_ce;
wire  [7:0]   s_hdr;
wire  [255:0] s_dat;
omac_40g_pcs_tx #(.AM_PERIOD(16384)) u_tx1 (
    .clk(clk), .rst(s_rst), .ce(s_ce), .xd(s_xd), .xc(s_xc), .gt_tx_hdr(s_hdr), .gt_tx_data(s_dat));

int          perm [4] = '{2, 0, 3, 1};      // receiver q gets PCS lane perm[q]
int          flip_lane = -1, flip_bit = 0, am_bad_lane = -1;
logic [3:0]  r_lock, r_aml, r_bip;
logic [7:0]  r_id;
logic [65:0] r_in [4];
always_comb begin
    for (int q = 0; q < 4; q++) begin
        r_in[q] = {s_dat[64*perm[q] +: 64], s_hdr[2*perm[q] +: 2]};
        if (q == flip_lane) r_in[q][flip_bit] = !r_in[q][flip_bit];
        if (q == am_bad_lane && am_match(r_in[q]) != 0) r_in[q][2] = !r_in[q][2];   // corrupt M0
    end
end
for (genvar q = 0; q < 4; q++) begin : g_rx
    wire ov, oam, oamk;
    wire [65:0] ob;
    omac_40g_lane_rx #(.AM_PERIOD(16384)) u_rx (
        .clk(clk), .rst(s_rst), .valid(1'b1), .hdr(r_in[q][1:0]), .data(r_in[q][65:2]), .slip(),
        .block_lock(r_lock[q]), .am_lock(r_aml[q]), .lane_id(r_id[2*q +: 2]), .ev_bip_error(r_bip[q]),
        .o_valid(ov), .o_am(oam), .o_amok(oamk), .o_blk(ob));
end
int bip_cnt [4] = '{0, 0, 0, 0};
always @(posedge clk) for (int q = 0; q < 4; q++) if (r_bip[q]) bip_cnt[q]++;

// byte-serial CRC reference over bytes [a, b) of d from state s
function automatic logic [31:0] crc_ref(logic [31:0] s, logic [255:0] d, int a, int b);
    for (int i = a; i < b; i++) s = crc32_byte(s, d[8*i +: 8]);
    return s;
endfunction

initial begin
    logic [65:0] blk, am2 [4];
    int nam, cyc, last_am, gap_bad, seqerr;
    logic [63:0] expv;
    // ---------------- 1. marker and BIP vectors (by hand) ----------------
    chk("AM lane 0 BIP 0x1E", am_block(2'd0, 8'h1E), {64'hE1B8_896F_1E47_7690, 2'b01});
    chk("AM lane 1 BIP 0x00", am_block(2'd1, 8'h00), {64'hFF19_3B0F_00E6_C4F0, 2'b01});
    chk("AM lane 2 BIP 0x5A", am_block(2'd2, 8'h5A), {64'hA564_9A3A_5A9B_65C5, 2'b01});
    chk("AM lane 3 BIP 0xFF", am_block(2'd3, 8'hFF), {64'h00C2_865D_FF3D_79A2, 2'b01});
    if (am_match({64'hA564_9A3A_5A9B_65C5, 2'b01}) !== 3'b110) begin $display("TB_ERR am_match lane 2"); errors++; end
    if (am_match({64'hA564_9A3A_5A9B_65C5, 2'b10}) !== 3'b000) begin $display("TB_ERR am_match data header"); errors++; end
    if (am_match({64'hA564_9A3A_5A9B_65C4, 2'b01}) !== 3'b000) begin $display("TB_ERR am_match bad M0"); errors++; end
    if (bip8({64'h1E, 2'b01}) !== 8'h16)                 begin $display("TB_ERR bip idle"); errors++; end
    if (bip8({64'h1, 2'b10}) !== 8'h11)                  begin $display("TB_ERR bip data 01"); errors++; end
    if (bip8({64'hFF00_0000_0000_0000, 2'b10}) !== 8'hEF) begin $display("TB_ERR bip data FF"); errors++; end
    if (bip8(am_block(2'd1, 8'h77)) !== 8'h08)            begin $display("TB_ERR bip of a marker"); errors++; end
    // ---------------- 2. pcs_tx markers, scrambler off ----------------
    t_xd = {32{XG_IDLE}};
    t_xc = '1;
    repeat (4) @(posedge clk);
    t_rst <= 1'b0;
    nam = 0; cyc = 0; last_am = -1; gap_bad = 0;
    while (nam < 4) begin
        @(posedge clk); cyc++;
        if (cyc == 20000) begin            // from here on data columns of 0x01 bytes
            t_xd = {4{64'h0000_0000_0000_0001}};
            t_xc = '0;
        end
        blk = {t_dat[63:0], t_hdr[1:0]};
        if (am_match(blk) != 0) begin
            for (int l = 0; l < 4; l++) begin
                am2[l] = {t_dat[64*l +: 64], t_hdr[2*l +: 2]};
                if (am_match(am2[l]) !== {1'b1, 2'(l)}) begin $display("TB_ERR lane %0d no marker in the marker cycle", l); errors++; end
            end
            if (last_am >= 0 && cyc - last_am != 16384) gap_bad++;
            last_am = cyc;
            nam++;
            if (nam == 2) begin
                chk("2nd marker lane 0 (idles: BIP 0x1E)", am2[0], {64'hE1B8_896F_1E47_7690, 2'b01});
                chk("2nd marker lane 1", am2[1], {64'hE119_3B0F_1EE6_C4F0, 2'b01});
                chk("2nd marker lane 2", am2[2], {64'hE164_9A3A_1E9B_65C5, 2'b01});
                chk("2nd marker lane 3", am2[3], {64'hE1C2_865D_1E3D_79A2, 2'b01});
            end
            if (nam == 4) begin
                chk("4th marker lane 0 (data 0x01: BIP 0x19)", am2[0], {64'hE6B8_896F_1947_7690, 2'b01});
                chk("4th marker lane 3", am2[3], {64'hE6C2_865D_193D_79A2, 2'b01});
            end
        end else if (cyc > 10 && cyc < 19990) begin
            for (int l = 0; l < 4; l++)
                if ({t_dat[64*l +: 64], t_hdr[2*l +: 2]} !== {64'h1E, 2'b01}) begin
                    if (errors < 5) $display("TB_ERR idle block expected lane %0d cyc %0d", l, cyc); errors++;
                end
        end
    end
    if (gap_bad) begin $display("TB_ERR marker spacing"); errors++; end
    $display("TB_INFO markers=%0d spacing=16384 vectors=4+4+4", nam);
    // ---------------- 3. ce: counter pattern, no loss around the marker ----------------
    begin
        logic [31:0] ctr, want, first;
        bit started;
        ctr = 0; want = 0; started = 0; seqerr = 0;
        t_xc = '0;
        for (int n = 0; n < 40000; n++) begin
            t_xd = {32'h0, ctr * 4 + 3, 32'h0, ctr * 4 + 2, 32'h0, ctr * 4 + 1, 32'h0, ctr * 4};
            @(posedge clk);
            if (t_ce) ctr++;
            // output: data blocks carry the counter (3 cycles of latency)
            blk = {t_dat[63:0], t_hdr[1:0]};
            if (n >= 6 && t_hdr[1:0] == SH_DATA) begin
                if (!started) begin started = 1; want = t_dat[31:0]; first = want; end
                for (int l = 0; l < 4; l++) if (t_dat[64*l +: 32] !== want + l) begin
                    seqerr++;
                end
                want = want + 4;
            end
        end
        if (seqerr) begin $display("TB_ERR ce: %0d sequence errors around the markers", seqerr); errors++; end
        $display("TB_INFO ce_sequence_errors=%0d blocks=%0d", seqerr, want - first);
    end
    // ---------------- 4. lane receivers ----------------
    s_xd = {32{XG_IDLE}};
    s_xc = '1;
    @(posedge clk); s_rst <= 1'b0;
    repeat (16384 * 3 + 500) @(posedge clk);
    for (int q = 0; q < 4; q++)
        if (!r_lock[q] || !r_aml[q] || r_id[2*q +: 2] != 2'(perm[q])) begin
            $display("TB_ERR lane rx %0d lock %0d aml %0d id %0d (want %0d)", q, r_lock[q], r_aml[q], r_id[2*q +: 2], perm[q]);
            errors++;
        end
    repeat (16384 * 2) @(posedge clk);
    if (bip_cnt[0] + bip_cnt[1] + bip_cnt[2] + bip_cnt[3] != 0) begin $display("TB_ERR BIP errors without errors"); errors++; end
    // one payload bit flip on receiver lane 1
    @(posedge clk); flip_lane = 1; flip_bit = 37;
    @(posedge clk); flip_lane = -1;
    repeat (16384 + 10) @(posedge clk);
    if (bip_cnt[1] != 1 || bip_cnt[0] + bip_cnt[2] + bip_cnt[3] != 0) begin
        $display("TB_ERR one flip: BIP errors %0d %0d %0d %0d", bip_cnt[0], bip_cnt[1], bip_cnt[2], bip_cnt[3]); errors++;
    end
    // one corrupted marker on receiver lane 3: lock kept
    am_bad_lane = 3;
    repeat (16384) @(posedge clk);
    am_bad_lane = -1;
    repeat (100) @(posedge clk);
    if (!r_aml[3]) begin $display("TB_ERR one bad marker dropped AM lock"); errors++; end
    // four in a row: lock lost
    am_bad_lane = 3;
    repeat (16384 * 4 + 10) @(posedge clk);
    if (r_aml[3]) begin $display("TB_ERR four bad markers kept AM lock"); errors++; end
    am_bad_lane = -1;
    repeat (16384 * 2 + 100) @(posedge clk);
    if (!r_aml[3] || r_id[7:6] != 2'(perm[3])) begin $display("TB_ERR AM lock not regained"); errors++; end
    $display("TB_INFO lane_rx bip=%0d,%0d,%0d,%0d ids=%02x", bip_cnt[0], bip_cnt[1], bip_cnt[2], bip_cnt[3], r_id);
    // ---------------- 5. CRC identities ----------------
    for (int n = 0; n < 3000; n++) begin
        logic [255:0] d, x;
        logic [31:0]  s, got, want, corr;
        int nb, o;
        d  = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
        s  = $urandom;
        nb = $urandom_range(32, 1);
        // TX / RX last beat: bytes [0, nb) from state s
        x    = (d ^ {224'd0, s}) & byte_mask(6'd0, 6'(nb));
        x    = x << (8 * (32 - nb));
        corr = (nb < 4) ? (s >> (8 * nb)) : 32'd0;
        got  = crc_z32(x) ^ corr;
        want = crc_ref(s, d, 0, nb);
        if (got !== want) begin if (errors < 10) $display("TB_ERR crc last nb=%0d", nb); errors++; end
        // full beat
        if (crc_z32(d ^ {224'd0, s}) !== crc_ref(s, d, 0, 32)) begin $display("TB_ERR crc full"); errors++; end
        // RX first beat: data from byte o (8, 16, 24), initial value
        o = 8 * $urandom_range(3, 1);
        got  = crc_z32((d & byte_mask(6'(o), 6'd32)) ^ ({224'd0, CRC_INIT} << (8 * o)));
        want = crc_ref(CRC_INIT, d, o, 32);
        if (got !== want) begin if (errors < 10) $display("TB_ERR crc first o=%0d", o); errors++; end
    end
    // residue: a 40-byte frame + FCS through the RX formulas (first beat at o = 8, end beat)
    begin
        logic [255:0] b0, b1, x;
        logic [31:0]  c, f;
        byte unsigned fr [40];
        foreach (fr[i]) fr[i] = 8'($urandom);
        c = CRC_INIT;
        foreach (fr[i]) c = crc32_byte(c, fr[i]);
        f = ~c;
        b0 = '0; b1 = '0;
        for (int i = 0; i < 24; i++) b0[8*(8+i) +: 8] = fr[i];
        for (int i = 24; i < 40; i++) b1[8*(i-24) +: 8] = fr[i];
        for (int i = 0; i < 4; i++) b1[8*(16+i) +: 8] = f[8*i +: 8];
        c = crc_z32((b0 & byte_mask(6'd8, 6'd32)) ^ ({224'd0, CRC_INIT} << 64));
        x = ((b1 ^ {224'd0, c}) & byte_mask(6'd0, 6'd20)) << (8 * 12);
        c = crc_z32(x);
        if (c !== CRC_RESIDUE) begin $display("TB_ERR residue %08x", c); errors++; end
    end
    $display("TB_INFO crc_cases=3000");
    if (errors == 0) $display("TB_PASS");
    else $display("TB_FAIL %0d", errors);
    $finish;
end

endmodule
