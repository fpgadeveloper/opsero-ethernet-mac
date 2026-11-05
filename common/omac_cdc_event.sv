// SPDX-License-Identifier: MIT
//
// omac_cdc_event - loss-free crossing of N event pulse streams from s_clk to
// m_clk. Each event has a CW-bit gray-coded counter in s_clk (it may pulse on
// every cycle); m_clk synchronises the counter and replays the difference as
// pulses, at most one per cycle and event. With two clocks of the same nominal
// frequency the backlog stays small; it must stay below 2^(CW-1) events.
// No counter is ever reset (so a reset of either side cannot fake events);
// while m_rst is high the replay continues but no pulse comes out.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_cdc_event #(
    parameter int N  = 1,
    parameter int CW = 6
) (
    input  wire logic         s_clk,
    input  wire logic [N-1:0] s_ev,
    input  wire logic         m_clk,
    input  wire logic         m_rst,
    output wire logic [N-1:0] m_ev
);

function automatic logic [CW-1:0] bin2gray(input logic [CW-1:0] b);
    return b ^ (b >> 1);
endfunction

function automatic logic [CW-1:0] gray2bin(input logic [CW-1:0] g);
    logic [CW-1:0] b;
    b[CW-1] = g[CW-1];
    for (int i = CW - 2; i >= 0; i--) b[i] = b[i+1] ^ g[i];
    return b;
endfunction

for (genvar e = 0; e < N; e++) begin : g_ev
    logic [CW-1:0] s_cnt = '0;
    logic [CW-1:0] s_gray = '0;
    always_ff @(posedge s_clk) begin
        if (s_ev[e]) s_cnt <= s_cnt + 1'b1;
        s_gray <= bin2gray(s_cnt);
    end
    (* ASYNC_REG = "TRUE" *) logic [CW-1:0] m_sync0 = '0, m_sync1 = '0;
    logic [CW-1:0] m_seen = '0;
    logic [CW-1:0] m_bin = '0;
    logic          m_pulse = 1'b0;
    always_ff @(posedge m_clk) begin
        m_sync0 <= s_gray;
        m_sync1 <= m_sync0;
        m_bin   <= gray2bin(m_sync1);
        if (m_seen != m_bin) m_seen <= m_seen + 1'b1;
        m_pulse <= (m_seen != m_bin) && !m_rst;
    end
    assign m_ev[e] = m_pulse;
end

endmodule

`resetall
