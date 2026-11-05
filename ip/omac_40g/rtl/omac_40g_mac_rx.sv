// SPDX-License-Identifier: MIT
//
// omac_40g_mac_rx - 256-bit RS + Ethernet MAC receive (in the common receive
// clock): XLGMII, four 8-byte columns per valid cycle -> 32-byte chunks of
// frames without FCS, written into two clock-crossing FIFO banks.
//   scan      per beat the columns are scanned in order: /S/ in lane 0 with the
//             SFD in lane 7 starts a frame (a start without SFD is ignored); the
//             first control character of a frame ends it, /T/ normally, anything
//             else (/E/ from the PCS, Local Fault, ...) as bad. Frames that start
//             and end inside one beat (at most 23 bytes with FCS) are counted as
//             runts and bad and are not delivered
//   CRC       running zero-state CRC over full beats (one-cycle loop; the first
//             beat's leading bytes are masked, the initial value XORed in at the
//             first data byte); the last beat right-aligned, residue check one
//             cycle later (omac_40g_pkg identities)
//   realign   frame data starts after the /S/ column, i.e. at byte 8, 16, 24 or
//             0 (next beat) of a beat; chunks are re-cut so that byte 0 of the
//             frame is chunk byte 0, from the previous beat (held) and the
//             current one. A chunk is only sent when at least 4 more bytes of the
//             frame follow it, so the FCS is never inside a non-last chunk and is
//             stripped from the last one; the end beat can produce two chunks
//   length    total length (with FCS) < MIN_FRAME: runt, bad; > MAX_FRAME: the
//             delivered frame is cut there (chunk shortened to MAX_FRAME) with
//             tuser = 1 and the rest discarded
//   control   frames with EtherType 0x8808 are consumed; a good PAUSE (opcode 1,
//             destination 01-80-C2-00-00-01 or mac_addr) pulses pause_ev
//   FIFO      chunks alternate between bank 0 and bank 1 (each written at most
//             once per cycle, read alternately on the other side). A chunk is
//             written only if the banks keep one entry spare afterwards; if not,
//             the frame is ended with a 1-byte tuser = 1 chunk in the spare entry
//             (if it had chunks in the FIFO already) or dropped, the rest of it
//             is discarded and ev_overflow pulses. This only happens when the
//             far end sends faster than one chunk per cycle for long (see the
//             IP page: frame sizes whose length without FCS is 1..7 mod 32 at
//             minimum gaps) or the user clock is slower than the receive clock
//             by more than the gaps allow.
// Chunk format: {user, last, nbytes[5:0], data[255:0]}.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_40g_mac_rx #(
    parameter int MIN_FRAME = 64,
    parameter int MAX_FRAME = 9600,
    parameter int FW        = 6        // bank free-count width
) (
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic          xvalid,
    input  wire logic [255:0]  xd,
    input  wire logic [31:0]   xc,

    input  wire logic          rx_enable,
    input  wire logic [47:0]   mac_addr,

    input  wire logic [FW-1:0] free0,
    input  wire logic [FW-1:0] free1,
    output logic               we0,
    output logic [263:0]       wd0,
    output logic               we1,
    output logic [263:0]       wd1,

    output logic               pause_ev,
    output logic [15:0]        pause_time,

    output logic               ev_good,
    output logic               ev_bad,
    output logic               ev_fcs_error,
    output logic               ev_runt,
    output logic               ev_oversize,
    output logic               ev_overflow
);

import omac_pkg::*;
import omac_40g_pkg::*;

localparam logic [47:0] PAUSE_DA = 48'h01_00_00_C2_80_01;

// ======================= stage 0: column scan (combinational) =======================
logic        inf = 1'b0;          // a frame is in progress at the start of the beat
logic        sc_end, sc_ok, sc_start, sc_intra, sc_inf;
logic [4:0]  sc_epos;
logic [1:0]  sc_scol;
always_comb begin
    logic       f, own;
    logic [3:0] p;
    logic       anyc;
    f = inf; own = inf;
    sc_end = 1'b0; sc_ok = 1'b0; sc_start = 1'b0; sc_intra = 1'b0;
    sc_epos = '0; sc_scol = '0;
    for (int j = 0; j < 4; j++) begin
        anyc = |xc[8*j +: 8];
        p = 4'd8;
        for (int b = 7; b >= 0; b--) if (xc[8*j + b]) p = 4'(b);
        if (f) begin
            if (anyc) begin
                f = 1'b0;
                if (own) begin
                    sc_end  = 1'b1;
                    sc_epos = 5'(8 * j + int'(p));
                    sc_ok   = (xd[64*j + 8*int'(p) +: 8] == XG_TERM);
                end else begin
                    sc_intra = 1'b1;
                end
                own = 1'b0;
            end
        end else if (xc[8*j +: 8] == 8'h01 && xd[64*j +: 8] == XG_START && xd[64*j + 56 +: 8] == ETH_SFD) begin
            f = 1'b1;
            own = 1'b0;
            sc_start = 1'b1;
            sc_scol  = 2'(j);
        end
    end
    sc_inf = f;
    sc_start = sc_start && f;     // a start whose frame continues into the next beat
end

// ======================= stage 1: CRC loop, length =======================
logic         s1_v = 1'b0, s1_cont, s1_end, s1_ok, s1_start, s1_intra;
logic [4:0]   s1_epos;
logic [1:0]   s1_scol;
logic [255:0] s1_d, s1_y;
logic [31:0]  s1_corr;
logic [15:0]  s1_len;              // mid beat: bytes so far; end beat: total with FCS
logic [31:0]  crc_s = CRC_INIT;
logic [15:0]  flen = '0;

wire  [5:0]   st_o  = 6'(8 * (int'(sc_scol) + 1));        // first data byte of a new frame (8..32)
wire  [255:0] z_in  = (sc_start && !(inf && !sc_end)) ?
                      ((xd & byte_mask(st_o, 6'd32)) ^ ({224'd0, CRC_INIT} << (8 * int'(st_o)))) :
                      (xd ^ {224'd0, crc_s});
wire  [31:0]  z_out = crc_z32(z_in);

always_ff @(posedge clk) begin
    logic [255:0] x;
    s1_v <= xvalid;
    if (xvalid) begin
        inf      <= sc_inf;
        s1_cont  <= inf;
        s1_end   <= sc_end;
        s1_ok    <= sc_ok;
        s1_start <= sc_start;
        s1_intra <= sc_intra;
        s1_epos  <= sc_epos;
        s1_scol  <= sc_scol;
        s1_d     <= xd;
        // last beat of the running frame: bytes [0, epos) right-aligned
        x        = (xd ^ {224'd0, crc_s}) & byte_mask(6'd0, 6'(sc_epos));
        s1_y    <= x << (8 * (32 - int'(sc_epos)));
        s1_corr <= (sc_epos < 5'd4) ? (crc_s >> (8 * int'(sc_epos))) : 32'd0;
        if (inf && !sc_end) begin
            crc_s  <= z_out;
            flen   <= (flen > 16'(MAX_FRAME + 64)) ? flen : flen + 16'd32;
            s1_len <= (flen > 16'(MAX_FRAME + 64)) ? flen : flen + 16'd32;
        end else if (inf) begin
            s1_len <= flen + 16'(sc_epos);
        end
        if (sc_start) begin
            crc_s <= (sc_scol == 2'd3) ? CRC_INIT : z_out;
            flen  <= 16'(32 - int'(st_o));
        end
    end
    if (rst) begin
        s1_v  <= 1'b0;
        inf   <= 1'b0;
        crc_s <= CRC_INIT;
    end
end

// ======================= stage 2: residue check, realign, write =======================
wire          fcs_ok = ((crc_z32(s1_y) ^ s1_corr) == CRC_RESIDUE);

logic         r_hh = 1'b0, r_drop = 1'b0, r_ctrl = 1'b0, r_da = 1'b0, r_op = 1'b0;
logic         r_disc = 1'b0, r_trunc = 1'b0, r_any = 1'b0;
logic [15:0]  r_pt = '0;
logic [1:0]   r_sh = '0;           // frame data offset in the beat / 8 (0 = byte 0 of the next beat)
logic [255:0] r_hold;
logic [9:0]   r_k = '0;            // chunks of this frame so far
logic         wb = 1'b0;           // bank of the next chunk

wire  [511:0] cat    = {s1_d, r_hold};
wire  [255:0] chA    = r_hh ? 256'(cat >> (64 * int'(r_sh))) : s1_d;
wire  [255:0] chB    = s1_d >> (64 * int'(r_sh));
wire  [5:0]   hcnt   = r_hh ? 6'(32 - 8 * int'(r_sh)) : 6'd0;
wire  signed [7:0] dlv = 8'(int'(hcnt) + int'(s1_epos) - 4);   // bytes left to deliver at the end beat
wire  [15:0]  done_b = {r_k, 5'd0};                              // bytes delivered before chunk A
wire  [15:0]  room_b = (16'(MAX_FRAME) > done_b) ? 16'(MAX_FRAME) - done_b : 16'd1;

// chunk A as the first chunk of a frame: its MAC fields
wire          a_first = (r_k == '0);
wire          a_ctrl  = {chA[103:96], chA[111:104]} == 16'h8808;
wire          a_da    = (chA[47:0] == PAUSE_DA) || (chA[47:0] == mac_addr);
wire          a_op    = {chA[119:112], chA[127:120]} == 16'h0001;
wire  [15:0]  a_pt    = {chA[135:128], chA[143:136]};
wire          ctrl_e  = a_first ? a_ctrl : r_ctrl;

function automatic logic [5:0] min32(input int v);
    return (v >= 32) ? 6'd32 : 6'(v);
endfunction

always_ff @(posedge clk) begin
    logic         eA, eB, lA, uA, uB;
    logic [5:0]   nA, nB;
    logic         show, bad, runt, over, fin, good_ev, bad_ev, ovf;
    logic [1:0]   nw;
    logic         room;
    logic [FW-1:0] f0, f1;
    we0 <= 1'b0;
    we1 <= 1'b0;
    pause_ev     <= 1'b0;
    ev_good      <= 1'b0;
    ev_bad       <= 1'b0;
    ev_fcs_error <= 1'b0;
    ev_runt      <= 1'b0;
    ev_oversize  <= 1'b0;
    ev_overflow  <= 1'b0;
    if (s1_v) begin
        eA = 1'b0; eB = 1'b0; lA = 1'b0; uA = 1'b0; uB = 1'b0; nA = 6'd32; nB = 6'd0;
        fin = 1'b0; good_ev = 1'b0; bad_ev = 1'b0;
        show = !r_drop && !ctrl_e && !r_disc && !r_trunc;
        runt = s1_len < 16'(MIN_FRAME);
        over = s1_len > 16'(MAX_FRAME);
        bad  = !s1_ok || !fcs_ok || runt || over;
        if (s1_cont && !r_disc) begin
            if (!s1_end) begin
                // a beat inside the frame: one chunk once a beat is held
                if (r_hh) begin
                    eA = 1'b1;
                    if (over) begin
                        // longer than MAX_FRAME: cut here
                        nA = min32(int'(room_b));
                        lA = 1'b1;
                        uA = 1'b1;
                        r_disc <= 1'b1;
                        ev_oversize <= 1'b1;
                        bad_ev = 1'b1;
                    end
                end
                r_hold <= s1_d;
                r_hh   <= 1'b1;
            end else begin
                // the end beat: one or two chunks
                ev_fcs_error <= s1_ok && !fcs_ok;
                ev_runt      <= runt;
                ev_oversize  <= over;
                fin = 1'b1;
                if (dlv <= 0) begin
                    bad_ev = 1'b1;                     // nothing left after the FCS
                end else if (over) begin
                    eA = 1'b1; lA = 1'b1; uA = 1'b1;
                    nA = min32((int'(dlv) < int'(room_b)) ? int'(dlv) : int'(room_b));
                    bad_ev = 1'b1;
                end else if (dlv <= 32) begin
                    eA = 1'b1; lA = 1'b1; uA = bad; nA = 6'(dlv);
                    good_ev = !bad; bad_ev = bad;
                end else begin
                    eA = 1'b1; eB = 1'b1; uB = bad; nB = 6'(dlv - 32);
                    good_ev = !bad; bad_ev = bad;
                end
                // a good PAUSE frame (consumed, never shown)
                if (ctrl_e && !bad && (a_first ? (a_op && a_da) : (r_op && r_da))) begin
                    pause_ev   <= 1'b1;
                    pause_time <= a_first ? a_pt : r_pt;
                end
            end
            if (eA && a_first) begin
                r_ctrl <= a_ctrl;
                r_da   <= a_da;
                r_op   <= a_op;
                r_pt   <= a_pt;
            end
            r_k <= r_k + 10'(eA) + 10'(eB);
        end
        if (s1_intra && rx_enable) begin
            ev_runt <= 1'b1;
            ev_bad  <= 1'b1;
        end
        // ---- FIFO banks: write the shown chunks if one entry stays spare ----
        if (!show) begin
            eA = 1'b0; eB = 1'b0;
        end
        // free entries: the write registered last cycle is not in the counts yet
        f0 = free0 - FW'(we0);
        f1 = free1 - FW'(we1);
        nw = 2'(eA) + 2'(eB);
        room = (nw == 2'd0) ||
               (nw == 2'd1 && (wb ? f1 : f0) >= FW'(1) && (wb ? f0 : f1) >= FW'(1)) ||
               (nw == 2'd2 && (wb ? f1 : f0) >= FW'(2) && (wb ? f0 : f1) >= FW'(1));
        ovf = !room;
        if (room) begin
            if (eA) begin
                if (!wb) begin we0 <= 1'b1; wd0 <= {uA, lA, nA, chA}; end
                else     begin we1 <= 1'b1; wd1 <= {uA, lA, nA, chA}; end
            end
            if (eB) begin
                if (wb)  begin we0 <= 1'b1; wd0 <= {uB, 1'b1, nB, chB}; end
                else     begin we1 <= 1'b1; wd1 <= {uB, 1'b1, nB, chB}; end
            end
            wb <= wb ^ (nw == 2'd1);
            if (nw != 2'd0) r_any <= 1'b1;
        end else begin
            // no room: end the frame in the spare entry (if it has chunks out) or drop it
            if (r_any) begin
                if (!wb) begin we0 <= 1'b1; wd0 <= {1'b1, 1'b1, 6'd1, chA}; end
                else     begin we1 <= 1'b1; wd1 <= {1'b1, 1'b1, 6'd1, chA}; end
                wb <= !wb;
            end
            r_trunc <= 1'b1;
            ev_overflow <= 1'b1;
        end
        if (show) begin
            ev_good <= good_ev && !ovf;
            ev_bad  <= (bad_ev && !ovf) || (ovf && r_any) || (s1_intra && rx_enable);
        end
        if (s1_cont && s1_end) begin
            r_hh    <= 1'b0;
            r_disc  <= 1'b0;
        end
        // a frame starting in this beat
        if (s1_start) begin
            r_sh    <= 2'(int'(s1_scol) + 1);
            r_hh    <= (s1_scol != 2'd3);
            r_hold  <= s1_d;
            r_k     <= '0;
            r_drop  <= !rx_enable;
            r_ctrl  <= 1'b0;
            r_disc  <= 1'b0;
            r_trunc <= 1'b0;
            r_any   <= 1'b0;
        end
    end
    if (rst) begin
        we0 <= 1'b0;
        we1 <= 1'b0;
        wb  <= 1'b0;
        r_hh <= 1'b0;
        r_disc <= 1'b0;
        r_trunc <= 1'b0;
        r_any <= 1'b0;
        r_k <= '0;
        pause_ev <= 1'b0;
        ev_good <= 1'b0;
        ev_bad <= 1'b0;
        ev_fcs_error <= 1'b0;
        ev_runt <= 1'b0;
        ev_oversize <= 1'b0;
        ev_overflow <= 1'b0;
    end
end

endmodule

`resetall
