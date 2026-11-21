// SPDX-License-Identifier: MIT
//
// omac_cdc_word - carries a slowly changing multi-bit value from one clock into
// another with a toggle handshake: the source captures `s_data` into a holding
// register and toggles a request; the destination, two synchroniser stages
// later, copies the (by then stable) holding register and returns the toggle
// as the acknowledge; the next capture follows when the acknowledge is back.
// The transfer runs continuously, so `m_data` follows `s_data` with a delay of
// about 3 destination + 3 source cycles and always shows a value that `s_data`
// really had (never a mix of two values). Changes shorter than one round trip
// can be skipped: use it for levels and states, not for events
// (omac_cdc_event counts events). The holding register -> `m_data` path is
// covered by the design's max-delay constraint between the two clocks.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_cdc_word #(
    parameter int         W    = 8,
    parameter logic [W-1:0] INIT = '0
) (
    input  wire logic         s_clk,
    input  wire logic [W-1:0] s_data,
    input  wire logic         m_clk,
    output logic      [W-1:0] m_data = INIT
);

logic [W-1:0] s_hold = INIT;
logic         s_req = 1'b0;
logic         m_ack = 1'b0;
(* ASYNC_REG = "TRUE" *) logic s_ack0 = 1'b0, s_ack1 = 1'b0;
always_ff @(posedge s_clk) begin
    s_ack0 <= m_ack;
    s_ack1 <= s_ack0;
    if (s_ack1 == s_req) begin
        s_hold <= s_data;
        s_req  <= !s_req;
    end
end

(* ASYNC_REG = "TRUE" *) logic m_req0 = 1'b0, m_req1 = 1'b0;
always_ff @(posedge m_clk) begin
    m_req0 <= s_req;
    m_req1 <= m_req0;
    if (m_req1 != m_ack) begin
        m_data <= s_hold;
        m_ack  <= m_req1;
    end
end

endmodule

`resetall
