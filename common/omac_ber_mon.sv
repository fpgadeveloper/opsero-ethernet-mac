// SPDX-License-Identifier: MIT
//
// omac_ber_mon - 64B/66B BER monitor (IEEE 802.3 clause 49.2.13.2.5, figure
// 49-15): while block lock is held, invalid sync headers are counted; THRESH of
// them within one TIMER_CLKS window set hi_ber at once; at the end of a window
// with fewer than THRESH, hi_ber clears. 10GBASE-R: 125 us and 16 (19532
// cycles at 156.25 MHz). Without block lock hi_ber is 0 and the window restarts.
// N > 1 tests N sync headers per cycle (40GBASE-R: the four lanes, clause 82
// figure 82-13, 97 invalid headers within 1.25 ms); each invalid one counts.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_ber_mon #(
    parameter int TIMER_CLKS = 19532,
    parameter int THRESH     = 16,
    parameter int N          = 1
) (
    input  wire logic       clk,
    input  wire logic       rst,
    input  wire logic       lock,
    input  wire logic       valid,
    input  wire logic [2*N-1:0] hdr,
    output logic            hi_ber,
    output logic            invalid_sh     // pulse per cycle with an invalid header while locked
);

localparam int TW = $clog2(TIMER_CLKS + 1);
localparam int CW = $clog2(THRESH + 1);

logic [TW-1:0] timer = '0;
logic [CW-1:0] ber_cnt = '0;

localparam int NW = $clog2(N + 1);

logic [NW-1:0] nbad;
always_comb begin
    nbad = '0;
    if (valid && lock) for (int i = 0; i < N; i++) nbad = nbad + NW'(!(hdr[2*i] ^ hdr[2*i+1]));
end
wire bad = (nbad != '0);

always_ff @(posedge clk) begin
    invalid_sh <= bad;
    if (timer == TW'(TIMER_CLKS - 1)) begin
        timer <= '0;
        if (ber_cnt < CW'(THRESH) && !bad) hi_ber <= 1'b0;
        ber_cnt <= (nbad >= THRESH) ? CW'(THRESH) : CW'(nbad);
        if (nbad >= THRESH) hi_ber <= 1'b1;
    end else begin
        timer <= timer + 1'b1;
        if (bad && ber_cnt < CW'(THRESH)) begin
            if (int'(ber_cnt) + int'(nbad) >= THRESH) begin
                ber_cnt <= CW'(THRESH);
                hi_ber  <= 1'b1;
            end else begin
                ber_cnt <= ber_cnt + CW'(nbad);
            end
        end
    end
    if (rst || !lock) begin
        timer   <= '0;
        ber_cnt <= '0;
        hi_ber  <= 1'b0;
        invalid_sh <= 1'b0;
    end
end

endmodule

`resetall
