// SPDX-License-Identifier: MIT
//
// omac_pause_frame - AXI-Stream source of one 802.3x PAUSE frame (annex 31B)
// without FCS: destination 01-80-C2-00-00-01, source `mac_addr` (byte 0 =
// mac_addr[7:0]), EtherType 0x8808, opcode 0x0001, pause_time (big-endian),
// 42 zero bytes = 60 bytes; the MAC appends the FCS. `start` (while idle)
// latches pause_time and the address and starts the frame; `busy` is high
// until the last beat has been accepted.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_pause_frame #(
    parameter int DATA_WIDTH = 64
) (
    input  wire logic                    clk,
    input  wire logic                    rst,
    input  wire logic                    start,
    input  wire logic [15:0]             pause_time,
    input  wire logic [47:0]             mac_addr,
    output logic                         busy,

    output wire logic [DATA_WIDTH-1:0]   m_axis_tdata,
    output wire logic [DATA_WIDTH/8-1:0] m_axis_tkeep,
    output wire logic                    m_axis_tvalid,
    input  wire logic                    m_axis_tready,
    output wire logic                    m_axis_tlast
);

localparam int KW    = DATA_WIDTH / 8;
localparam int BEATS = (60 + KW - 1) / KW;
localparam int LASTN = 60 - (BEATS - 1) * KW;

logic [479:0] frame = '0;     // 60 bytes, byte i = frame[8*i +: 8]
logic [$clog2(BEATS+1)-1:0] beat = '0;

always_ff @(posedge clk) begin
    if (!busy && start) begin
        busy  <= 1'b1;
        beat  <= '0;
        frame <= '0;
        frame[47:0]    <= 48'h01_00_00_C2_80_01;          // 01-80-C2-00-00-01
        frame[95:48]   <= mac_addr;
        frame[111:96]  <= 16'h08_88;                       // 0x8808, big-endian
        frame[127:112] <= 16'h01_00;                       // opcode 0x0001
        frame[143:128] <= {pause_time[7:0], pause_time[15:8]};
    end else if (busy && m_axis_tready) begin
        beat <= beat + 1'b1;
        if (beat == ($bits(beat))'(BEATS - 1)) busy <= 1'b0;
    end
    if (rst) begin
        busy <= 1'b0;
        beat <= '0;
    end
end

logic [8*KW*BEATS-1:0] padded;
assign padded = {{(8*KW*BEATS - 480){1'b0}}, frame};
assign m_axis_tdata  = padded[DATA_WIDTH * beat +: DATA_WIDTH];
assign m_axis_tvalid = busy;
assign m_axis_tlast  = (beat == ($bits(beat))'(BEATS - 1));
assign m_axis_tkeep  = m_axis_tlast ? ({KW{1'b1}} >> (KW - LASTN)) : {KW{1'b1}};

endmodule

`resetall
