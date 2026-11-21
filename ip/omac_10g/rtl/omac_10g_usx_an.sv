// SPDX-License-Identifier: MIT
//
// omac_10g_usx_an - USXGMII auto-negotiation (omac_10g, USXGMII_EN = 1): the
// exchange of the 16-bit configuration word with the PHY and the resolution of
// the replication factor.
//
// The word (EDCS-1517762 table 2, the same bits as Linux MDIO_USXGMII_*):
//   15 link, 14 acknowledge, 12 full duplex, 11:9 speed (000 10M, 001 100M,
//   010 1G, 011 10G, 100 2.5G, 101 5G), 8 EEE, 7 EEE clock stop, 0 = 1.
// On the line (EDCS-1517762 1.1.2): an XGMII sequence ordered set, lane 0 /Q/
// (0x9C), lane 1 word[15:8], lane 2 word[7:0], lane 3 the opcode 0x03 (LSWAP = 1
// exchanges lanes 1 and 2, OPCODE is a parameter). Transmitted in both halves
// of every column (block type 0x55, TXFMT = 0) or in the low half with idles
// above (block type 0x4B, TXFMT = 1); received in either half of any column.
//
// Arbitration: IEEE 802.3 clause 37 figure 37-6 without next pages, with the
// USXGMII changes listed in EDCS-1517762 1.1.1 / 2.5: restart when block lock
// is lost (instead of an_sync_status = FAIL), idles received in AN_RESTART /
// ABILITY_DETECT / ACKNOWLEDGE_DETECT restart (instead of RUDI(INVALID);
// IDLE_RESTART = 0 disables it), link timer programmable (1 to 2 ms in the
// specification; `link_timer` in clk cycles, 0 = LINK_TIMER).
//   receive (rx clock): every configuration ordered set gives a word;
//     ability_match = three consecutive words equal except bit 14;
//     acknowledge_match = three consecutive equal words with bit 14 set;
//     idle_match = three consecutive idle words. Single idle words between
//     configuration words do not break a run; three idle words or any other
//     word (data, error, fault, LPI) end it.
//   arbitration (clk): AN_ENABLE -> AN_RESTART (send 0, link timer) ->
//     ABILITY_DETECT (send adv, wait for ability_match with a non-zero word)
//     -> ACKNOWLEDGE_DETECT (send adv + ack, wait for acknowledge_match with the
//     same word: consistent, else restart) -> COMPLETE_ACKNOWLEDGE (link timer)
//     -> IDLE_DETECT (send idles, link timer + idle_match) -> LINK_OK (data).
//     A zero word (ability_match) restarts from ACKNOWLEDGE_DETECT,
//     COMPLETE_ACKNOWLEDGE and IDLE_DETECT; any ability_match in LINK_OK
//     restarts (the PHY signals a link change by sending words again).
//   resolution: at LINK_OK the partner's word (lp_word, the word acknowledged)
//     gives speed, duplex and link; rep_n follows the speed. link_ok = LINK_OK
//     with the partner's link bit set and a defined speed code.
//   an_enable = 0: AN_DISABLE_LINK_OK, data at force_speed, link_ok = 1.
// xmit: 0 = configuration columns (cfg_d / cfg_c), 1 = idles, 2 = data.
// Status values for software in clk; state codes as the localparams below.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_usx_an #(
    parameter int         LINK_TIMER   = 250000,
    parameter logic [7:0] OPCODE       = 8'h03,
    parameter bit         LSWAP        = 1'b0,
    parameter bit         TXFMT        = 1'b0,
    parameter bit         IDLE_RESTART = 1'b1
) (
    // transmit clock
    input  wire logic        clk,
    input  wire logic        rst,
    input  wire logic        rx_up,
    input  wire logic        an_enable,
    input  wire logic        an_restart,
    input  wire logic [15:0] adv,
    input  wire logic [2:0]  force_speed,
    input  wire logic [19:0] link_timer,

    output logic      [1:0]  xmit = 2'd0,
    output logic      [63:0] cfg_d,
    output logic      [7:0]  cfg_c,
    output logic      [9:0]  rep_n = 10'd1,
    output logic             link_ok = 1'b0,
    output logic             an_complete = 1'b0,
    output logic      [2:0]  state,
    output logic      [15:0] lp_word = '0,
    output logic      [2:0]  speed = 3'd3,
    output logic             ev_start = 1'b0,
    output logic             ev_done = 1'b0,

    // receive clock
    input  wire logic        rx_clk,
    input  wire logic        rx_rst,
    input  wire logic        rx_valid,
    input  wire logic [63:0] rx_d,
    input  wire logic [7:0]  rx_c,
    output wire logic [9:0]  rx_rep_n
);

import omac_pkg::*;

localparam logic [2:0] S_ENABLE = 3'd0, S_RESTART = 3'd1, S_ABILITY = 3'd2, S_ACK = 3'd3,
                       S_COMPLETE = 3'd4, S_IDLE = 3'd5, S_LINK_OK = 3'd6, S_DISABLED = 3'd7;
localparam logic [15:0] ACK = 16'h4000;

function automatic logic [9:0] rep_of(input logic [2:0] sp);
    case (sp)
        3'd0:    return 10'd1000;
        3'd1:    return 10'd100;
        3'd2:    return 10'd10;
        3'd4:    return 10'd4;
        3'd5:    return 10'd2;
        default: return 10'd1;
    endcase
endfunction

// ---------------- receive: configuration words and the match functions ----------------
logic [15:0] r_last = '0;
logic [1:0]  r_nab = '0, r_nack = '0, r_nidle = '0;

always_ff @(posedge rx_clk) begin
    logic [15:0] lw, cw;
    logic [1:0]  na, nk, ni;
    logic [31:0] w;
    logic [3:0]  c;
    lw = r_last; na = r_nab; nk = r_nack; ni = r_nidle;
    if (rx_valid) begin
        for (int h = 0; h < 2; h++) begin
            w = rx_d[32*h +: 32];
            c = rx_c[4*h +: 4];
            if (c == 4'b0001 && w[7:0] == XG_SEQ && w[31:24] == OPCODE) begin
                cw = LSWAP ? {w[23:16], w[15:8]} : {w[15:8], w[23:16]};
                ni = '0;
                if (((cw ^ lw) & ~ACK) == '0) begin if (na != 2'd3) na = na + 1'b1; end
                else na = 2'd1;
                if (cw == lw) begin if (nk != 2'd3) nk = nk + 1'b1; end
                else nk = 2'd1;
                lw = cw;
            end else if (c == 4'hF && w == {4{XG_IDLE}}) begin
                if (ni != 2'd3) ni = ni + 1'b1;
                if (ni == 2'd3) begin na = '0; nk = '0; end
            end else begin
                na = '0; nk = '0; ni = '0;
            end
        end
    end
    r_last <= lw; r_nab <= na; r_nack <= nk; r_nidle <= ni;
    if (rx_rst) begin
        r_nab <= '0; r_nack <= '0; r_nidle <= '0;
    end
end

logic [18:0] m_snap;
omac_cdc_word #(.W(19)) u_cdc_rx (.s_clk(rx_clk),
    .s_data({r_nab == 2'd3, r_nack == 2'd3 && r_last[14], r_nidle == 2'd3, r_last}),
    .m_clk(clk), .m_data(m_snap));
wire        abil  = m_snap[18];
wire        ackm  = m_snap[17];
wire        idlem = m_snap[16];
wire [15:0] rword = m_snap[15:0];

omac_cdc_word #(.W(10), .INIT(10'd1)) u_cdc_rep (.s_clk(clk), .s_data(rep_n), .m_clk(rx_clk), .m_data(rx_rep_n));

// ---------------- arbitration (clk) ----------------
logic [2:0]  st = S_ENABLE, nx;
logic [19:0] lt = '0;
logic [15:0] abil_word = '0, tx_cfg = '0;
logic        restart_d = 1'b0, en_d = 1'b0;
wire  [19:0] ltv = (link_timer != '0) ? link_timer : 20'(LINK_TIMER);
wire         lt_done = (lt == '0);
wire         zero_rx = abil && (rword == '0);
assign state = st;

always_comb begin
    nx = st;
    case (st)
        S_ENABLE:   nx = S_RESTART;
        S_RESTART:  if (lt_done) nx = S_ABILITY;
        S_ABILITY:  if (abil && rword != '0) nx = S_ACK;
        S_ACK:      if (ackm && ((rword ^ abil_word) & ~ACK) == '0) nx = S_COMPLETE;
                    else if (ackm || zero_rx) nx = S_ENABLE;
        S_COMPLETE: if (zero_rx) nx = S_ENABLE;
                    else if (lt_done) nx = S_IDLE;
        S_IDLE:     if (zero_rx) nx = S_ENABLE;
                    else if (lt_done && idlem) nx = S_LINK_OK;
        S_LINK_OK:  if (abil) nx = S_ENABLE;
        default:    nx = S_ENABLE;          // S_DISABLED, left below
    endcase
    if (IDLE_RESTART && idlem && (st == S_RESTART || st == S_ABILITY || st == S_ACK)) nx = S_ENABLE;
    if (!an_enable) nx = S_DISABLED;
    else if (st == S_DISABLED || !rx_up || (an_restart && !restart_d)) nx = S_ENABLE;
    if (rst) nx = an_enable ? S_ENABLE : S_DISABLED;
end

always_ff @(posedge clk) begin
    restart_d <= an_restart;
    en_d      <= an_enable;
    st        <= nx;
    ev_start  <= (nx == S_ENABLE) && (st >= S_ABILITY) && !rst;
    ev_done   <= (nx == S_LINK_OK) && (st != S_LINK_OK);
    if (lt != '0) lt <= lt - 1'b1;
    if (nx != st && (nx == S_RESTART || nx == S_COMPLETE || nx == S_IDLE)) lt <= ltv;
    if (st == S_ABILITY && nx == S_ACK) abil_word <= rword;
    if (st == S_ACK && nx == S_COMPLETE) lp_word <= rword;
    case (nx)
        S_ENABLE, S_RESTART: begin tx_cfg <= '0;          xmit <= 2'd0; end
        S_ABILITY:           begin tx_cfg <= adv & ~ACK;  xmit <= 2'd0; end
        S_ACK, S_COMPLETE:   begin tx_cfg <= adv | ACK;   xmit <= 2'd0; end
        S_IDLE:              begin                        xmit <= 2'd1; end
        default:             begin                        xmit <= 2'd2; end
    endcase
    // resolution
    an_complete <= (nx == S_LINK_OK);
    if (nx == S_DISABLED) begin
        speed   <= force_speed;
        rep_n   <= rep_of(force_speed);
        link_ok <= (force_speed <= 3'd5);
    end else if (nx == S_LINK_OK) begin
        if (st != S_LINK_OK) begin
            speed <= lp_word[11:9];
            rep_n <= rep_of(lp_word[11:9]);
        end
        link_ok <= lp_word[15] && (lp_word[11:9] <= 3'd5);
    end else begin
        link_ok <= 1'b0;
    end
end

// the configuration column: lane 0 /Q/, lanes 1-2 the word, lane 3 the opcode
wire [31:0] os_w = LSWAP ? {OPCODE, tx_cfg[15:8], tx_cfg[7:0], XG_SEQ} : {OPCODE, tx_cfg[7:0], tx_cfg[15:8], XG_SEQ};
assign cfg_d = TXFMT ? {{4{XG_IDLE}}, os_w} : {os_w, os_w};
assign cfg_c = TXFMT ? 8'hF1 : 8'h11;

endmodule

`resetall
