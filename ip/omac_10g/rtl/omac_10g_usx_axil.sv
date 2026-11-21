// SPDX-License-Identifier: MIT
//
// omac_10g_usx_axil - optional AXI4-Lite register block for the USXGMII
// controls and status of omac_10g (USXGMII_EN = 1); not part of the IP itself
// (omac_10g stays driver-less: a design may fold the ctl_usx_* / stat_usx_*
// ports into its own registers instead). All in the IP's clk; put a clock
// converter in front for another AXI clock. The registers are what a Linux
// phylink PCS driver needs (pcs_get_state, pcs_config, pcs_an_restart,
// pcs_link_up): see docs/usxgmii.md.
// Register map (byte addresses, 32-bit registers, unused addresses read 0,
// every access is OKAY):
//   0x00 ID          0x55535847 ("USXG")
//   0x04 VERSION     VERSION parameter
//   0x08 CTRL        [0] AN_ENABLE (reset 1), [1] AN_RESTART (write 1: restart,
//                    reads 0), [2] RX_STRICT, [6:4] FORCE_SPEED (speed code
//                    with AN_ENABLE = 0, reset 3 = 10G)
//   0x0C ADV         [15:0] our configuration word (reset ADV_INIT; bit 14 is
//                    set by the arbitration)
//   0x10 LINK_TIMER  [19:0] auto-negotiation link timer in clk cycles, 0 = the
//                    IP's USX_LINK_TIMER parameter
//   0x14 STATUS      [0] LINK_UP (stat_link_up), [1] BLOCK_LOCK, [2] USX_LINK_OK
//                    (AN complete with the PHY's link bit, or AN off),
//                    [3] AN_COMPLETE, [6:4] AN_STATE, [10:8] SPEED (code in use),
//                    [11] LP_LINK, [12] LP_FULL_DUPLEX (from LP_WORD)
//   0x18 LP_WORD     [15:0] the PHY's acknowledged word (Linux: the "lpa" for
//                    phylink_decode_usxgmii_word)
//   0x1C EVENTS      sticky, write 1 to clear: [0] REP_ERROR, [1] AN_RESTART
//                    (an exchange started again), [2] AN_DONE, [3] LINK_DOWN,
//                    [4] LINK_UP (edges of stat_link_up)
//   0x20 IRQ_EN      [4:0] irq = |(EVENTS & IRQ_EN)
//   0x24 REP_ERRORS  replica mismatches (saturating 32 bits; any write clears)
//   0x28 AN_DONES    completed exchanges (saturating; any write clears)
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_10g_usx_axil #(
    parameter logic [31:0] VERSION  = 32'h0000_0100,
    parameter logic [15:0] ADV_INIT = 16'h9601
) (
    input  wire logic        clk,
    input  wire logic        rst,

    // to / from omac_10g
    output logic             ctl_usx_an_enable = 1'b1,
    output logic             ctl_usx_an_restart = 1'b0,
    output logic      [15:0] ctl_usx_an_adv = ADV_INIT,
    output logic      [2:0]  ctl_usx_speed = 3'd3,
    output logic      [19:0] ctl_usx_link_timer = '0,
    output logic             ctl_usx_rx_strict = 1'b0,
    input  wire logic        stat_link_up,
    input  wire logic        stat_block_lock,
    input  wire logic        stat_usx_an_complete,
    input  wire logic [2:0]  stat_usx_an_state,
    input  wire logic [15:0] stat_usx_lp_word,
    input  wire logic [2:0]  stat_usx_speed,
    input  wire logic        stat_usx_link_ok,
    input  wire logic        ev_usx_an_start,
    input  wire logic        ev_usx_an_done,
    input  wire logic        ev_usx_rep_error,

    output logic             irq = 1'b0,

    input  wire logic [11:0] s_axil_awaddr,
    input  wire logic        s_axil_awvalid,
    output logic             s_axil_awready,
    input  wire logic [31:0] s_axil_wdata,
    input  wire logic [3:0]  s_axil_wstrb,
    input  wire logic        s_axil_wvalid,
    output logic             s_axil_wready,
    output logic [1:0]       s_axil_bresp,
    output logic             s_axil_bvalid,
    input  wire logic        s_axil_bready,
    input  wire logic [11:0] s_axil_araddr,
    input  wire logic        s_axil_arvalid,
    output logic             s_axil_arready,
    output logic [31:0]      s_axil_rdata,
    output logic [1:0]       s_axil_rresp,
    output logic             s_axil_rvalid,
    input  wire logic        s_axil_rready
);

logic [4:0]  events = '0, irq_en = '0;
logic [31:0] rep_cnt = '0, an_cnt = '0;
logic        link_d = 1'b0;

wire [31:0] status = {19'd0, stat_usx_lp_word[12], stat_usx_lp_word[15], 1'b0, stat_usx_speed, 1'b0,
                      stat_usx_an_state, stat_usx_an_complete, stat_usx_link_ok, stat_block_lock, stat_link_up};

// write channel: accept address and data together
always_ff @(posedge clk) begin
    logic [4:0] clr;
    logic       clr_rep, clr_an;
    clr = '0; clr_rep = 1'b0; clr_an = 1'b0;
    ctl_usx_an_restart <= 1'b0;
    s_axil_awready <= 1'b0;
    s_axil_wready  <= 1'b0;
    if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
    if (s_axil_awvalid && s_axil_wvalid && !s_axil_awready && !s_axil_bvalid) begin
        s_axil_awready <= 1'b1;
        s_axil_wready  <= 1'b1;
        s_axil_bvalid  <= 1'b1;
        case (s_axil_awaddr[11:2])
            10'h002: if (s_axil_wstrb[0]) begin
                ctl_usx_an_enable  <= s_axil_wdata[0];
                ctl_usx_an_restart <= s_axil_wdata[1];
                ctl_usx_rx_strict  <= s_axil_wdata[2];
                ctl_usx_speed      <= s_axil_wdata[6:4];
            end
            10'h003: begin
                if (s_axil_wstrb[0]) ctl_usx_an_adv[7:0]  <= s_axil_wdata[7:0];
                if (s_axil_wstrb[1]) ctl_usx_an_adv[15:8] <= s_axil_wdata[15:8];
            end
            10'h004: begin
                if (s_axil_wstrb[0]) ctl_usx_link_timer[7:0]   <= s_axil_wdata[7:0];
                if (s_axil_wstrb[1]) ctl_usx_link_timer[15:8]  <= s_axil_wdata[15:8];
                if (s_axil_wstrb[2]) ctl_usx_link_timer[19:16] <= s_axil_wdata[19:16];
            end
            10'h007: if (s_axil_wstrb[0]) clr = s_axil_wdata[4:0];
            10'h008: if (s_axil_wstrb[0]) irq_en <= s_axil_wdata[4:0];
            10'h009: clr_rep = 1'b1;
            10'h00A: clr_an = 1'b1;
            default: ;
        endcase
    end
    // events, counters
    link_d <= stat_link_up;
    events <= (events & ~clr) | {stat_link_up && !link_d, !stat_link_up && link_d, ev_usx_an_done,
                                 ev_usx_an_start, ev_usx_rep_error};
    if (clr_rep)                                   rep_cnt <= '0;
    else if (ev_usx_rep_error && rep_cnt != '1)    rep_cnt <= rep_cnt + 1'b1;
    if (clr_an)                                    an_cnt <= '0;
    else if (ev_usx_an_done && an_cnt != '1)       an_cnt <= an_cnt + 1'b1;
    irq <= |(events & irq_en);
    if (rst) begin
        s_axil_awready <= 1'b0;
        s_axil_wready  <= 1'b0;
        s_axil_bvalid  <= 1'b0;
        ctl_usx_an_enable  <= 1'b1;
        ctl_usx_an_restart <= 1'b0;
        ctl_usx_an_adv     <= ADV_INIT;
        ctl_usx_speed      <= 3'd3;
        ctl_usx_link_timer <= '0;
        ctl_usx_rx_strict  <= 1'b0;
        events  <= '0;
        irq_en  <= '0;
        rep_cnt <= '0;
        an_cnt  <= '0;
        irq     <= 1'b0;
    end
end
assign s_axil_bresp = 2'b00;

// read channel
always_ff @(posedge clk) begin
    s_axil_arready <= 1'b0;
    if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 1'b0;
    if (s_axil_arvalid && !s_axil_arready && !s_axil_rvalid) begin
        s_axil_arready <= 1'b1;
        s_axil_rvalid  <= 1'b1;
        case (s_axil_araddr[11:2])
            10'h000: s_axil_rdata <= 32'h5553_5847;
            10'h001: s_axil_rdata <= VERSION;
            10'h002: s_axil_rdata <= {25'd0, ctl_usx_speed, 1'b0, ctl_usx_rx_strict, 1'b0, ctl_usx_an_enable};
            10'h003: s_axil_rdata <= {16'd0, ctl_usx_an_adv};
            10'h004: s_axil_rdata <= {12'd0, ctl_usx_link_timer};
            10'h005: s_axil_rdata <= status;
            10'h006: s_axil_rdata <= {16'd0, stat_usx_lp_word};
            10'h007: s_axil_rdata <= {27'd0, events};
            10'h008: s_axil_rdata <= {27'd0, irq_en};
            10'h009: s_axil_rdata <= rep_cnt;
            10'h00A: s_axil_rdata <= an_cnt;
            default: s_axil_rdata <= '0;
        endcase
    end
    if (rst) begin
        s_axil_arready <= 1'b0;
        s_axil_rvalid  <= 1'b0;
    end
end
assign s_axil_rresp = 2'b00;

endmodule

`resetall
