// SPDX-License-Identifier: MIT
//
// tb_gt_chan - behavioural model of a transmitter -> cable -> receiver gearbox
// for one 64B/66B lane, in the transmitter's clock (the receiver's recovered
// clock is the far end's TX clock). The 66-bit blocks of the sender (IEEE bit
// order: hdr[0] first, then data[0..63]) form a serial stream; the receiver
// presents 66-bit windows of it starting at bit offset `phase` (random at
// start, so block lock must search for the boundary). A slip pulse moves the
// window by one bit after a random latency of 2..24 cycles.
// Error injection:
//   hdr_rate  > 0: on average one sync-header bit flip per hdr_rate blocks
//   burst     > 0: the next `burst` blocks get an invalid header
//   dflip     > 0: one payload bit flip in a data block every >= dflip blocks,
//                  at most one per frame (re-armed by the next control block);
//                  never in the first data block after a control block (for a
//                  lane-4 start it carries the preamble and SFD: a hit there
//                  makes the frame disappear, correctly); n_dflip counts them
//   kill      = 1: every header invalid (no lock possible)
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1fs
`default_nettype none

module tb_gt_chan (
    input  wire logic        clk,
    input  wire logic [1:0]  tx_hdr,
    input  wire logic [63:0] tx_data,
    input  wire logic        rx_slip,
    output logic      [1:0]  rx_hdr,
    output logic      [63:0] rx_data,
    output logic             rx_valid
);

int hdr_rate = 0;
int burst    = 0;
int dflip    = 0;
bit kill     = 1'b0;
int n_dflip  = 0;
int n_hdr    = 0;
int n_slip   = 0;
int phase;

logic [65:0] prev = '0, cur = '0;
int  slip_cd = 0;
int  dcount = 0;
bit  armed = 1'b1;
bit  prev_ctrl = 1'b1;

initial begin
    phase = $urandom_range(65);
    rx_valid = 1'b0;
end

always @(posedge clk) begin
    logic [65:0]  b;
    logic [131:0] v;
    int           fbit;
    b = {tx_data, tx_hdr};
    if (kill) b[0] = b[1];
    if (burst > 0) begin
        b[0] = b[1];
        burst = burst - 1;
        n_hdr++;
    end
    if (hdr_rate > 0 && $urandom_range(hdr_rate - 1) == 0) begin
        b[0] = !b[0];
        n_hdr++;
    end
    if (dflip > 0) begin
        dcount++;
        if (tx_hdr == 2'b01) armed = 1'b1;
        if (armed && dcount >= dflip && tx_hdr == 2'b10 && !prev_ctrl) begin
            fbit = 2 + $urandom_range(63);
            b[fbit] = !b[fbit];
            armed  = 1'b0;
            dcount = 0;
            n_dflip++;
        end
    end
    prev_ctrl = (tx_hdr == 2'b01);
    prev <= cur;
    cur  <= b;
    v = {cur, prev};
    v = v >> phase;
    rx_hdr   <= v[1:0];
    rx_data  <= v[65:2];
    rx_valid <= 1'b1;
    if (rx_slip && slip_cd == 0) begin
        slip_cd = $urandom_range(24, 2);
        n_slip++;
    end
    if (slip_cd > 0) begin
        slip_cd = slip_cd - 1;
        if (slip_cd == 0) phase = (phase == 65) ? 0 : phase + 1;
    end
end

endmodule
