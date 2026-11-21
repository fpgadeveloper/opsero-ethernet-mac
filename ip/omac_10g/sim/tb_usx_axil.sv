// SPDX-License-Identifier: MIT
//
// tb_usx_axil - self-checking unit test of omac_10g_usx_axil: reset values, every
// read/write register and byte strobe, the AN_RESTART pulse, the status word
// against driven status inputs, sticky events (write 1 to clear), the
// interrupt mask, the saturating counters and their clear. Prints TB_CHECK
// lines and TB_RESULT errors=<n>.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_usx_axil;

logic clk = 1'b0, rst = 1'b1;
always #3.2 clk = ~clk;

logic [11:0] awaddr = '0, araddr = '0;
logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b1, arvalid = 1'b0, rready = 1'b1;
logic [31:0] wdata = '0;
logic [3:0]  wstrb = '0;
wire         awready, wready, bvalid, arready, rvalid;
wire  [1:0]  bresp, rresp;
wire  [31:0] rdata;

wire         an_en, an_rst, strict, irq;
wire  [15:0] adv;
wire  [2:0]  fsp;
wire  [19:0] ltm;
logic        link = 1'b0, lock = 1'b0, cpl = 1'b0, lok = 1'b0, ev_s = 1'b0, ev_d = 1'b0, ev_r = 1'b0;
logic [2:0]  ast = '0, spd = '0;
logic [15:0] lpw = '0;

omac_10g_usx_axil dut (
    .clk(clk), .rst(rst),
    .ctl_usx_an_enable(an_en), .ctl_usx_an_restart(an_rst), .ctl_usx_an_adv(adv), .ctl_usx_speed(fsp),
    .ctl_usx_link_timer(ltm), .ctl_usx_rx_strict(strict),
    .stat_link_up(link), .stat_block_lock(lock), .stat_usx_an_complete(cpl), .stat_usx_an_state(ast),
    .stat_usx_lp_word(lpw), .stat_usx_speed(spd), .stat_usx_link_ok(lok),
    .ev_usx_an_start(ev_s), .ev_usx_an_done(ev_d), .ev_usx_rep_error(ev_r), .irq(irq),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready), .s_axil_wdata(wdata),
    .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready), .s_axil_bresp(bresp),
    .s_axil_bvalid(bvalid), .s_axil_bready(bready), .s_axil_araddr(araddr), .s_axil_arvalid(arvalid),
    .s_axil_arready(arready), .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid),
    .s_axil_rready(rready));

int errors = 0;
task automatic check(string what, logic [31:0] got, logic [31:0] exp);
    $display("TB_CHECK %s %s got=0x%08x exp=0x%08x", (got === exp) ? "ok" : "FAIL", what, got, exp);
    if (got !== exp) errors++;
endtask

task automatic wr(logic [11:0] a, logic [31:0] d, logic [3:0] s = 4'hF);
    @(posedge clk);
    awaddr <= a; wdata <= d; wstrb <= s; awvalid <= 1'b1; wvalid <= 1'b1;
    do @(posedge clk); while (!awready);
    awvalid <= 1'b0; wvalid <= 1'b0;
    while (!bvalid) @(posedge clk);
endtask

task automatic rd(logic [11:0] a, output logic [31:0] d);
    @(posedge clk);
    araddr <= a; arvalid <= 1'b1;
    do @(posedge clk); while (!arready);
    arvalid <= 1'b0;
    while (!rvalid) @(posedge clk);
    d = rdata;
endtask

int pulses = 0;
always @(posedge clk) if (an_rst) pulses++;

task automatic pulse(input int which, input int n);    // 0 rep_error, 1 an_start, 2 an_done
    for (int i = 0; i < n; i++) begin
        @(posedge clk);
        case (which) 0: ev_r <= 1'b1; 1: ev_s <= 1'b1; default: ev_d <= 1'b1; endcase
        @(posedge clk);
        ev_r <= 1'b0; ev_s <= 1'b0; ev_d <= 1'b0;
    end
endtask

initial begin
    logic [31:0] v;
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (3) @(posedge clk);
    rd(12'h000, v); check("ID", v, 32'h5553_5847);
    rd(12'h004, v); check("VERSION", v, 32'h0000_0100);
    rd(12'h008, v); check("CTRL reset (AN on, 10G)", v, 32'h0000_0031);
    rd(12'h00C, v); check("ADV reset", v, 32'h0000_9601);
    rd(12'h010, v); check("LINK_TIMER reset", v, 32'h0);
    check("ports at reset", {an_en, strict, fsp, adv, 4'h0, ltm[3:0]}, {1'b1, 1'b0, 3'd3, 16'h9601, 8'h00});
    // CTRL: AN off, strict, forced 1G; the restart bit pulses once and reads 0
    wr(12'h008, 32'h0000_0024);
    rd(12'h008, v); check("CTRL write", v, 32'h0000_0024);
    check("CTRL ports", {an_en, strict, fsp}, {1'b0, 1'b1, 3'd2});
    wr(12'h008, 32'h0000_0033);
    repeat (3) @(posedge clk);
    rd(12'h008, v); check("CTRL restart reads 0", v, 32'h0000_0031);
    check("AN_RESTART: one pulse", pulses, 1);
    // ADV, LINK_TIMER with byte strobes
    wr(12'h00C, 32'h0000_D201, 4'b0001);
    rd(12'h00C, v); check("ADV low byte only", v, 32'h0000_9601);
    wr(12'h00C, 32'h0000_D201, 4'b0011);
    rd(12'h00C, v); check("ADV", v, 32'h0000_D201);
    check("ADV port", adv, 16'hD201);
    wr(12'h010, 32'hFFF3_D090);
    rd(12'h010, v); check("LINK_TIMER (20 bits)", v, 32'h0003_D090);
    check("LINK_TIMER port", ltm, 20'h3_D090);
    // STATUS / LP_WORD
    link <= 1'b1; lock <= 1'b1; cpl <= 1'b1; lok <= 1'b1; ast <= 3'd6; spd <= 3'd4; lpw <= 16'hD801;
    repeat (2) @(posedge clk);
    rd(12'h014, v); check("STATUS", v, {19'd0, 1'b1, 1'b1, 1'b0, 3'd4, 1'b0, 3'd6, 1'b1, 1'b1, 1'b1, 1'b1});
    rd(12'h018, v); check("LP_WORD", v, 32'h0000_D801);
    lpw <= 16'h0401;
    repeat (2) @(posedge clk);
    rd(12'h014, v); check("STATUS lp link 0, half duplex", v[12:11], 2'b00);
    // events: link up seen (above), now link down, AN start / done, replica errors
    link <= 1'b0;
    pulse(0, 5); pulse(1, 2); pulse(2, 3);
    repeat (2) @(posedge clk);
    rd(12'h01C, v); check("EVENTS all set", v, 32'h1F);
    check("irq masked", irq, 1'b0);
    wr(12'h020, 32'h0000_0008);
    repeat (2) @(posedge clk);
    check("irq on LINK_DOWN", irq, 1'b1);
    wr(12'h01C, 32'h0000_0009);
    repeat (2) @(posedge clk);
    rd(12'h01C, v); check("EVENTS W1C", v, 32'h16);
    check("irq cleared", irq, 1'b0);
    rd(12'h024, v); check("REP_ERRORS", v, 5);
    rd(12'h028, v); check("AN_DONES", v, 3);
    wr(12'h024, 32'h0);
    rd(12'h024, v); check("REP_ERRORS cleared", v, 0);
    rd(12'h028, v); check("AN_DONES kept", v, 3);
    rd(12'h0FC, v); check("unused address", v, 0);
    // reset
    rst <= 1'b1; @(posedge clk); rst <= 1'b0; repeat (2) @(posedge clk);
    rd(12'h008, v); check("CTRL after reset", v, 32'h0000_0031);
    rd(12'h01C, v); check("EVENTS after reset", v, 32'h0);
    $display("TB_RESULT errors=%0d", errors);
    $finish;
end

endmodule
