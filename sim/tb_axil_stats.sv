// SPDX-License-Identifier: MIT
//
// tb_axil_stats - omac_axil_stats: ID / NCNT / STATUS reads, random event
// pulses counted exactly (48-bit low/high read), clear. TB_PASS / TB_FAIL.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_axil_stats;

localparam int N = 5;
logic clk = 1'b0, rst = 1'b1;
always #2 clk = ~clk;
logic [N-1:0] ev = '0;
logic [31:0]  stat = 32'hA5A5_0001;
logic [11:0] awaddr, araddr;
logic awvalid = 1'b0, wvalid = 1'b0, bready = 1'b1, arvalid = 1'b0, rready = 1'b1;
logic [31:0] wdata;
wire  awready, wready, bvalid, arready, rvalid;
wire  [1:0] bresp, rresp;
wire  [31:0] rdata;

omac_axil_stats #(.NCNT(N)) dut (.clk(clk), .rst(rst), .ev(ev), .stat(stat),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready));

task automatic rd(input logic [11:0] a, output logic [31:0] d);
    @(posedge clk); araddr <= a; arvalid <= 1'b1;
    do @(posedge clk); while (!arready);
    arvalid <= 1'b0;
    while (!rvalid) @(posedge clk);
    d = rdata;
endtask

task automatic wr(input logic [11:0] a, input logic [31:0] d);
    @(posedge clk); awaddr <= a; wdata <= d; awvalid <= 1'b1; wvalid <= 1'b1;
    do @(posedge clk); while (!awready);
    awvalid <= 1'b0; wvalid <= 1'b0;
    while (!bvalid) @(posedge clk);
endtask

int expc [N];
int errors = 0;
initial begin
    logic [31:0] d, h;
    repeat (4) @(posedge clk); rst <= 1'b0;
    rd(12'h000, d); if (d != 32'h4F4D_4143) errors++;
    rd(12'h008, d); if (d != N) errors++;
    rd(12'h00C, d); if (d != stat) errors++;
    for (int t = 0; t < 2000; t++) begin
        @(posedge clk);
        for (int i = 0; i < N; i++) begin
            ev[i] <= ($urandom_range(3) == 0);
        end
        #0;
    end
    @(posedge clk); ev <= '0;
    repeat (3) @(posedge clk);
    for (int i = 0; i < N; i++) begin
        rd(12'h100 + 8 * i, d); rd(12'h104 + 8 * i, h);
        if (d != expc[i] || h != 0) begin $display("TB_ERR counter %0d = %0d, want %0d", i, d, expc[i]); errors++; end
    end
    wr(12'h010, 32'h1);
    repeat (2) @(posedge clk);
    rd(12'h100, d); if (d != 0) begin $display("TB_ERR clear"); errors++; end
    if (errors == 0) $display("TB_PASS"); else $display("TB_FAIL %0d", errors);
    $finish;
end

always @(posedge clk) if (!rst) for (int i = 0; i < N; i++) if (ev[i]) expc[i]++;

endmodule
