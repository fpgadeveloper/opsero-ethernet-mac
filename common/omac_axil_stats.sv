// SPDX-License-Identifier: MIT
//
// omac_axil_stats - optional AXI4-Lite statistics block for any omac IP (not
// part of the mandatory boundary). One 48-bit counter per event input (the
// ev_* pulses), the stat_* levels as a status word. All in one clock (the
// IP's clk); put a clock converter in front for another AXI clock.
// Register map (byte addresses, 32-bit registers):
//   0x000 ID        0x4F4D4143 ("OMAC")
//   0x004 VERSION   VERSION parameter
//   0x008 NCNT      number of counters
//   0x00C STATUS    stat[31:0] (live)
//   0x010 CTRL      write 1 to bit 0: clear every counter (self-clearing)
//   0x100 + 8*i     counter i, bits 31:0; reading it latches bits 47:32
//   0x104 + 8*i     counter i, bits 47:32 as latched by the last low read
// Counters saturate at 2^48-1. Unused addresses read 0; every access is OKAY.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_axil_stats #(
    parameter int          NCNT    = 12,
    parameter logic [31:0] VERSION = 32'h0000_0100
) (
    input  wire logic            clk,
    input  wire logic            rst,

    input  wire logic [NCNT-1:0] ev,
    input  wire logic [31:0]     stat,

    input  wire logic [11:0]     s_axil_awaddr,
    input  wire logic            s_axil_awvalid,
    output logic                 s_axil_awready,
    input  wire logic [31:0]     s_axil_wdata,
    input  wire logic [3:0]      s_axil_wstrb,
    input  wire logic            s_axil_wvalid,
    output logic                 s_axil_wready,
    output logic [1:0]           s_axil_bresp,
    output logic                 s_axil_bvalid,
    input  wire logic            s_axil_bready,
    input  wire logic [11:0]     s_axil_araddr,
    input  wire logic            s_axil_arvalid,
    output logic                 s_axil_arready,
    output logic [31:0]          s_axil_rdata,
    output logic [1:0]           s_axil_rresp,
    output logic                 s_axil_rvalid,
    input  wire logic            s_axil_rready
);

logic [47:0] cnt [NCNT];
logic [15:0] hi_latch = '0;
logic        clr = 1'b0;

always_ff @(posedge clk) begin
    for (int i = 0; i < NCNT; i++) begin
        if (clr) cnt[i] <= '0;
        else if (ev[i] && cnt[i] != '1) cnt[i] <= cnt[i] + 1'b1;
    end
    if (rst) for (int i = 0; i < NCNT; i++) cnt[i] <= '0;
end

// write channel: accept address and data together
always_ff @(posedge clk) begin
    clr <= 1'b0;
    s_axil_awready <= 1'b0;
    s_axil_wready  <= 1'b0;
    if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
    if (s_axil_awvalid && s_axil_wvalid && !s_axil_awready && !s_axil_bvalid) begin
        s_axil_awready <= 1'b1;
        s_axil_wready  <= 1'b1;
        s_axil_bvalid  <= 1'b1;
        if (s_axil_awaddr[11:2] == 10'h004 && s_axil_wstrb[0] && s_axil_wdata[0]) clr <= 1'b1;
    end
    if (rst) begin
        s_axil_awready <= 1'b0;
        s_axil_wready  <= 1'b0;
        s_axil_bvalid  <= 1'b0;
    end
end
assign s_axil_bresp = 2'b00;

// read channel
always_ff @(posedge clk) begin
    logic [9:0] w;
    int idx;
    s_axil_arready <= 1'b0;
    if (s_axil_rvalid && s_axil_rready) s_axil_rvalid <= 1'b0;
    if (s_axil_arvalid && !s_axil_arready && !s_axil_rvalid) begin
        s_axil_arready <= 1'b1;
        s_axil_rvalid  <= 1'b1;
        w = s_axil_araddr[11:2];
        s_axil_rdata <= '0;
        case (w)
            10'h000: s_axil_rdata <= 32'h4F4D_4143;
            10'h001: s_axil_rdata <= VERSION;
            10'h002: s_axil_rdata <= 32'(NCNT);
            10'h003: s_axil_rdata <= stat;
            default: begin
                if (w >= 10'h040) begin
                    idx = (w - 10'h040) >> 1;
                    if (idx < NCNT) begin
                        if (!w[0]) begin
                            s_axil_rdata <= cnt[idx][31:0];
                            hi_latch     <= cnt[idx][47:32];
                        end else begin
                            s_axil_rdata <= {16'd0, hi_latch};
                        end
                    end
                end
            end
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
