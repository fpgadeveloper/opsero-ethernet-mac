// SPDX-License-Identifier: MIT
//
// omac_crc32 - combinational Ethernet CRC-32 update over the first `nbytes`
// bytes (0..BYTES) of a BYTES-wide word. Byte i = data[8*i +: 8], bit 0 first
// (the reflected CRC of IEEE 802.3 clause 3.2.9: polynomial 0x04C11DB7 shifted
// LSB first, i.e. 0xEDB88320). crc_out is the raw register (not inverted):
//   start a frame with crc_in = 32'hFFFFFFFF; FCS = ~crc_out after the last
//   byte, transmitted fcs[7:0] first; a received frame including its FCS is
//   good when crc_out == 32'hDEBB20E3 (omac_pkg::CRC_RESIDUE).
// Structure: one linear network per byte count (part[k] = CRC after k bytes)
// and a multiplexer on nbytes. The networks share their leading terms, so the
// cost grows with BYTES^2: intended for BYTES <= 16; wider IPs pipeline it.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_crc32 #(
    parameter int BYTES = 8
) (
    input  wire logic [31:0]              crc_in,
    input  wire logic [8*BYTES-1:0]       data,
    input  wire logic [$clog2(BYTES+1)-1:0] nbytes,
    output wire logic [31:0]              crc_out
);

logic [31:0] part [BYTES+1];

always_comb begin
    part[0] = crc_in;
    for (int k = 1; k <= BYTES; k++) part[k] = omac_pkg::crc32_byte(part[k-1], data[8*(k-1) +: 8]);
end

assign crc_out = (nbytes > BYTES) ? part[BYTES] : part[nbytes];

endmodule

`resetall
