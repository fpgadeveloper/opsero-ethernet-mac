// SPDX-License-Identifier: MIT
//
// omac_pause - IEEE 802.3 annex 31B PAUSE timing, speed-independent.
//   Receive: a valid PAUSE frame (rx_load pulse with rx_quanta) loads the pause
//   timer with rx_quanta x 512 bit times; the timer counts down BIT_TIMES_PER_CLK
//   bit times per cycle (64 for a 64-bit datapath at its line rate, 256 for a
//   256-bit datapath at 40G); rx_pause_req is high while it runs. quanta 0 (XON)
//   clears it. 1 quantum = 8 cycles at 10G/156.25 MHz (51.2 ns) and at
//   25G/390.625 MHz (20.48 ns).
//   Transmit: tx_send is a level. Its rising edge requests an XOFF frame (pause
//   time tx_quanta), repeated every tx_refresh quanta while tx_send stays high
//   (0 = no repeat); its falling edge requests one XON. tx_req / tx_req_xon go to
//   the frame source, which pulses tx_ack when it has taken the request.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_pause #(
    parameter int BIT_TIMES_PER_CLK = 64
) (
    input  wire logic        clk,
    input  wire logic        rst,

    input  wire logic        rx_load,
    input  wire logic [15:0] rx_quanta,
    output wire logic        rx_pause_req,

    input  wire logic        tx_send,
    input  wire logic [15:0] tx_refresh,
    output logic             tx_req,       // a PAUSE frame is wanted
    output logic             tx_req_xon,   // ... and it is an XON (pause time 0)
    input  wire logic        tx_ack,       // the frame source took the request
    output logic             tx_xoff_active
);

localparam int BPC = BIT_TIMES_PER_CLK;

// ---------------- receive timer (bit times) ----------------
logic [25:0] rx_timer = '0;
always_ff @(posedge clk) begin
    if (rx_load)                 rx_timer <= {rx_quanta, 9'd0};
    else if (rx_timer > 26'(BPC)) rx_timer <= rx_timer - 26'(BPC);
    else                         rx_timer <= '0;
    if (rst) rx_timer <= '0;
end
assign rx_pause_req = (rx_timer != '0);

// ---------------- transmit requests ----------------
logic        send_d = 1'b0;
logic [25:0] ref_timer = '0;
always_ff @(posedge clk) begin
    send_d <= tx_send;
    if (tx_ack) begin
        tx_req <= 1'b0;
        if (!tx_req_xon) begin
            tx_xoff_active <= 1'b1;
            ref_timer <= {tx_refresh, 9'd0};
        end
    end else if (ref_timer != '0) begin
        if (ref_timer > 26'(BPC)) ref_timer <= ref_timer - 26'(BPC);
        else begin
            ref_timer <= '0;
            if (tx_send && tx_xoff_active) begin
                tx_req     <= 1'b1;
                tx_req_xon <= 1'b0;
            end
        end
    end
    if (tx_send && !send_d) begin
        tx_req     <= 1'b1;
        tx_req_xon <= 1'b0;
    end else if (!tx_send && send_d) begin
        tx_req     <= 1'b1;
        tx_req_xon <= 1'b1;
        tx_xoff_active <= 1'b0;
        ref_timer  <= '0;
    end
    if (rst) begin
        send_d <= 1'b0;
        tx_req <= 1'b0;
        tx_req_xon <= 1'b0;
        tx_xoff_active <= 1'b0;
        ref_timer <= '0;
    end
end

endmodule

`resetall
