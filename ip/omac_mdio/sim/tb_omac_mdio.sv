// SPDX-License-Identifier: MIT
//
// tb_omac_mdio - omac_mdio against three behavioural PHYs on one MDC/MDIO bus
// (tb_mdio_phy, 5 ns board delay each way, MDIO pulled up):
//   PHY 1: clause 22 + 45, needs the full preamble
//   PHY 5: clause 22 + 45, accepts preamble suppression
//   PHY 9: clause 22 only
//   address 7: nobody
// Phases: reset values, clause 22, absent PHY, clause 45 (separate frames, ADDR_FIRST,
// post-read-increment), back-to-back commands and frame time, MDC divider sweep,
// preamble length / suppression, free-running MDC, hold-off (input and CFG), abort and
// resynchronisation, bit-bang mode, interrupt, command while busy, bus error
// (readback), AXI corner cases, and a random soak. Self-checking against a mirror of
// every register written; continuous checks: MDC high / low time, MDIO setup and hold
// at the PHY (>= 10 ns), no bus contention (master and a PHY driving together), MDIO
// released while idle, open-drain outputs never drive a 1. Prints TB_RES lines and
// TB_PASS / TB_FAIL.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_omac_mdio #(
    parameter int CLK_HALF_PS = 5000,   // 100 MHz
    parameter int OPEN_DRAIN  = 0,
    parameter int SYNC_STAGES = 2,
    parameter int DIV_INIT    = 19,     // 2.5 MHz at 100 MHz
    parameter int SOAK        = 300
);

localparam real TCLK = 2.0 * CLK_HALF_PS / 1000.0;   // ns
localparam int  DIV0 = DIV_INIT;

logic clk = 1'b0, rst = 1'b1;
always #(CLK_HALF_PS / 1000.0) clk = ~clk;

// ---------------------------------------------------------------- DUT
logic [11:0] awaddr = '0, araddr = '0;
logic        awvalid = 1'b0, wvalid = 1'b0, bready = 1'b1, arvalid = 1'b0, rready = 1'b1;
logic [31:0] wdata = '0;
logic [3:0]  wstrb = 4'hF;
wire         awready, wready, bvalid, arready, rvalid;
wire  [1:0]  bresp, rresp;
wire  [31:0] rdata;
logic        hold = 1'b0;
wire         irq, mdc, mdio_o, mdio_t;
tri1         mdio;

omac_mdio #(.DIV_INIT(DIV0), .PRE_INIT(32), .OPEN_DRAIN(OPEN_DRAIN), .SYNC_STAGES(SYNC_STAGES)) dut (
    .clk(clk), .rst(rst),
    .s_axil_awaddr(awaddr), .s_axil_awvalid(awvalid), .s_axil_awready(awready),
    .s_axil_wdata(wdata), .s_axil_wstrb(wstrb), .s_axil_wvalid(wvalid), .s_axil_wready(wready),
    .s_axil_bresp(bresp), .s_axil_bvalid(bvalid), .s_axil_bready(bready),
    .s_axil_araddr(araddr), .s_axil_arvalid(arvalid), .s_axil_arready(arready),
    .s_axil_rdata(rdata), .s_axil_rresp(rresp), .s_axil_rvalid(rvalid), .s_axil_rready(rready),
    .irq(irq), .hold(hold), .mdc(mdc), .mdio_i(mdio), .mdio_o(mdio_o), .mdio_t(mdio_t));

// the bus: 5 ns board delay from the master to the PHYs (MDC, MDIO) and back (in the PHY)
wire mdc_phy;
assign #5 mdc_phy = mdc;
assign #5 mdio = mdio_t ? 1'bz : mdio_o;
logic stuck_low = 1'b0;
assign (supply0, highz1) mdio = stuck_low ? 1'b0 : 1'bz;   // a short to ground wins over any driver

tb_mdio_phy #(.ADDR(1), .C22(1), .C45(1), .MIN_PRE(32)) u_phy1 (.mdc(mdc_phy), .mdio(mdio));
tb_mdio_phy #(.ADDR(5), .C22(1), .C45(1), .MIN_PRE(1))  u_phy5 (.mdc(mdc_phy), .mdio(mdio));
tb_mdio_phy #(.ADDR(9), .C22(1), .C45(0), .MIN_PRE(32)) u_phy9 (.mdc(mdc_phy), .mdio(mdio));

int errors = 0;

// ---------------------------------------------------------------- continuous checks
// The master owns the bus when its output stage drives (or, open-drain, means to drive
// a 1 by releasing): mirror of the output register, delayed like the bus.
logic own_q = 1'b0;
always @(posedge clk) own_q <= dut.bb_en ? dut.bb_oe : !dut.eng_t;
wire own_d;
assign #5 own_d = own_q;
int contention = 0;
always @(own_d or u_phy1.oe_d or u_phy5.oe_d or u_phy9.oe_d) begin
    if ((own_d + u_phy1.oe_d + u_phy5.oe_d + u_phy9.oe_d) > 1) begin
        contention++;
        if (contention < 5) $display("TB_ERR contention at %t: master %b phy1 %b phy5 %b phy9 %b",
                                     $realtime, own_d, u_phy1.oe_d, u_phy5.oe_d, u_phy9.oe_d);
    end
end

// open-drain: never drive a 1
int od_err = 0;
always @(posedge clk) if (OPEN_DRAIN && !mdio_t && mdio_o) od_err++;

// MDC high / low time at the PHY
bit  chk_mdc = 1'b1, chk_sh = 1'b1;
real half_exp = (DIV0 + 1) * TCLK;
bit  free_mode = 1'b0;
realtime t_r = 0, t_f = 0;
int mdc_err = 0;
always @(posedge mdc_phy) begin
    if (chk_mdc && t_f > 0) begin
        real low;
        low = $realtime - t_f;
        if (low < half_exp - 0.01 || (free_mode && low > half_exp + 0.01)) begin
            mdc_err++;
            if (mdc_err < 5) $display("TB_ERR MDC low %0.3f ns, want %0.3f at %t", low, half_exp, $realtime);
        end
    end
    t_r = $realtime;
end
always @(negedge mdc_phy) begin
    if (chk_mdc && t_r > 0) begin
        real high;
        high = $realtime - t_r;
        if (high < half_exp - 0.01 || high > half_exp + 0.01) begin
            mdc_err++;
            if (mdc_err < 5) $display("TB_ERR MDC high %0.3f ns, want %0.3f at %t", high, half_exp, $realtime);
        end
    end
    t_f = $realtime;
end

// MDIO setup / hold at the PHY (the level the master puts on the bus; released = 1)
wire lvl = mdio_t ? 1'b1 : mdio_o;
wire lvl_d;
assign #5 lvl_d = lvl;
realtime t_lvl = -1000, t_rise = -1000;
real min_setup = 1.0e9, min_hold = 1.0e9;
int sh_err = 0;
always @(lvl_d) begin
    if (chk_sh) begin
        if ($realtime - t_rise < min_hold) min_hold = $realtime - t_rise;
        if ($realtime - t_rise < 10.0) begin
            sh_err++;
            if (sh_err < 5) $display("TB_ERR MDIO hold %0.3f ns at %t", $realtime - t_rise, $realtime);
        end
    end
    t_lvl = $realtime;
end
always @(posedge mdc_phy) begin
    if (chk_sh) begin
        if ($realtime - t_lvl < min_setup) min_setup = $realtime - t_lvl;
        if ($realtime - t_lvl < 10.0) begin
            sh_err++;
            if (sh_err < 5) $display("TB_ERR MDIO setup %0.3f ns at %t", $realtime - t_lvl, $realtime);
        end
    end
    t_rise = $realtime;
end

int n_rise = 0;
always @(posedge mdc_phy) n_rise++;

// busy time of every command (cycles from accept to done)
int busy_cyc = 0, last_busy = 0;
always @(posedge clk) begin
    if (dut.st_busy) busy_cyc++;
    else if (busy_cyc != 0) begin
        last_busy = busy_cyc;
        busy_cyc = 0;
    end
end

// ---------------------------------------------------------------- AXI-Lite
task automatic rd(input logic [11:0] a, output logic [31:0] d);
    @(posedge clk); araddr <= a; arvalid <= 1'b1;
    do @(posedge clk); while (!arready);
    arvalid <= 1'b0;
    while (!rvalid) @(posedge clk);
    d = rdata;
    if (rresp != 2'b00) begin errors++; $display("TB_ERR rresp"); end
endtask

task automatic wr(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s = 4'hF);
    @(posedge clk); awaddr <= a; wdata <= d; wstrb <= s; awvalid <= 1'b1; wvalid <= 1'b1;
    do @(posedge clk); while (!awready);
    awvalid <= 1'b0; wvalid <= 1'b0;
    while (!bvalid) @(posedge clk);
    if (bresp != 2'b00) begin errors++; $display("TB_ERR bresp"); end
endtask

localparam logic [11:0] A_ID = 12'h000, A_VER = 12'h004, A_CFG = 12'h008, A_CMD = 12'h00C,
                        A_WD = 12'h010, A_RD = 12'h014, A_ST = 12'h018, A_CTL = 12'h01C, A_BB = 12'h020;

// ---------------------------------------------------------------- mirror
logic [15:0] e22 [int];
logic [15:0] e45 [int];
logic [15:0] earg [int];

function automatic logic [15:0] i22(int pa, int a);
    return 16'h2200 ^ 16'(pa << 8) ^ 16'(a * 16'h0101);
endfunction
function automatic logic [15:0] i45(int pa, int dev, int a);
    return 16'((a * 40503) ^ (dev << 11) ^ (pa << 6) ^ 16'h5A5A);
endfunction
function automatic logic [15:0] x22(int pa, int a);
    int k = pa * 32 + a;
    return e22.exists(k) ? e22[k] : i22(pa, a);
endfunction
function automatic logic [15:0] x45(int pa, int dev, int a);
    int k = (pa * 32 + dev) * 65536 + a;
    return e45.exists(k) ? e45[k] : i45(pa, dev, a);
endfunction
function automatic logic [15:0] xarg(int pa, int dev);
    int k = pa * 32 + dev;
    return earg.exists(k) ? earg[k] : 16'h0000;
endfunction
function automatic bit answers(int pa, bit c45);
    if (pa == 1 || pa == 5) return 1'b1;
    if (pa == 9) return !c45;
    return 1'b0;
endfunction

int cur_div = DIV0, cur_pre = 32;
int n_ops = 0, n_rd_ok = 0, n_ta_err = 0;

// one command; checks the result against the mirror and updates it
task automatic cmd(input int op, input bit c45, input bit a1st, input int pa, input int ra,
                   input logic [15:0] d, input logic [15:0] a = 16'h0, input bit expect_answer = 1'b1);
    logic [31:0] st, r, c;
    bit rdop, two;
    int k, t0;
    logic [15:0] exp;
    rdop = c45 ? op[1] : (op == 2);
    two  = c45 && a1st && op != 0;
    wr(A_WD, {a, d});
    c = 32'(op) | (32'(c45) << 2) | (32'(a1st) << 3) | (32'(pa) << 8) | (32'(ra) << 16);
    wr(A_CMD, c);
    t0 = 0;
    do begin
        rd(A_ST, st);
        t0++;
    end while (st[0] && t0 < 200000);
    if (st[0]) begin errors++; $display("TB_ERR command timeout"); return; end
    n_ops++;
    if (!st[1]) begin errors++; $display("TB_ERR DONE not set"); end
    if (st[6] || st[5] || st[4]) begin errors++; $display("TB_ERR status %h", st); end
    if (!mdio_t) begin errors++; $display("TB_ERR MDIO not released after the command"); end
    // the address frame of a two-frame command
    if (two && answers(pa, 1'b1)) earg[pa * 32 + ra] = a;
    if (c45 && op == 0 && answers(pa, 1'b1)) earg[pa * 32 + ra] = d;
    if (rdop) begin
        rd(A_RD, r);
        if (answers(pa, c45) && expect_answer) begin
            if (!c45) exp = x22(pa, ra);
            else exp = x45(pa, ra, xarg(pa, ra));
            if (st[3] || !st[2] || !r[16] || r[15:0] !== exp) begin
                errors++;
                $display("TB_ERR read pa %0d c45 %0d op %0d dev/reg %0d: %h (status %h), want %h",
                         pa, c45, op, ra, r, st, exp);
            end else n_rd_ok++;
            if (c45 && op == 2) earg[pa * 32 + ra] = xarg(pa, ra) + 16'd1;
        end else begin
            if (!st[3] || st[2] || r[16] || r[15:0] !== 16'hFFFF) begin
                errors++;
                $display("TB_ERR no-answer read pa %0d: %h (status %h)", pa, r, st);
            end else n_ta_err++;
        end
    end else if (st[3] || st[2]) begin
        errors++;
        $display("TB_ERR write status %h", st);
    end
    if (!rdop && answers(pa, c45)) begin
        if (!c45) e22[pa * 32 + ra] = d;
        else if (op == 1) e45[(pa * 32 + ra) * 65536 + xarg(pa, ra)] = d;
    end
endtask

task automatic set_cfg(input int div, input int pre, input bit free, input bit irq_en = 0, input bit h = 0);
    wr(A_CFG, 32'(div) | (32'(pre) << 8) | (32'(free) << 16) | (32'(irq_en) << 17) | (32'(h) << 18));
    cur_div = div;
    cur_pre = pre;
    free_mode = free;
    half_exp = (div + 1) * TCLK;
    t_r = 0;
    t_f = 0;
    // PHY output delay: up to 300 ns, less than one MDC period minus the round trip
    begin
        real per, tmax;
        per = 2.0 * (div + 1) * TCLK;
        tmax = per - 2.0 * 5.0 - 2.0 * TCLK * (SYNC_STAGES + 1);
        if (tmax > 300.0) tmax = 300.0;
        if (tmax < 1.0) tmax = 1.0;
        u_phy1.tout_max = tmax;
        u_phy5.tout_max = tmax;
        u_phy9.tout_max = tmax;
    end
endtask

task automatic wait_idle_us(input real us);
    #(us * 1000.0);
endtask

task automatic check(input bit cond, input string what);
    if (!cond) begin
        errors++;
        $display("TB_ERR %s", what);
    end
endtask

// a random command (used by several phases)
task automatic rand_cmd(input bit only_answering = 1'b0);
    int pas [4] = '{1, 5, 9, 7};
    int pa, kind, ra;
    logic [15:0] d, a;
    pa = pas[$urandom_range(only_answering ? 2 : 3)];
    kind = $urandom_range(7);
    ra = $urandom_range(31);
    d = 16'($urandom);
    a = 16'($urandom);
    if (pa == 9 && kind >= 2) kind = kind & 1;
    case (kind)
        0: cmd(2'b01, 0, 0, pa, ra, d);             // c22 write
        1: cmd(2'b10, 0, 0, pa, ra, d);             // c22 read
        2: cmd(2'b00, 1, 0, pa, ra, a);             // c45 address
        3: cmd(2'b01, 1, 0, pa, ra, d);             // c45 write
        4: cmd(2'b11, 1, 0, pa, ra, d);             // c45 read
        5: cmd(2'b10, 1, 0, pa, ra, d);             // c45 post-read-increment
        6: cmd(2'b01, 1, 1, pa, ra, d, a);          // c45 address + write
        7: cmd(2'b11, 1, 1, pa, ra, d, a);          // c45 address + read
    endcase
endtask

// ---------------------------------------------------------------- test program
initial begin
    logic [31:0] d, st;
    int r0, r1, t0, c0, exp_cyc;
    $display("TB_INFO clk %0.3f ns, OPEN_DRAIN %0d, SYNC_STAGES %0d", TCLK, OPEN_DRAIN, SYNC_STAGES);
    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (5) @(posedge clk);
    set_cfg(DIV0, 32, 0);

    // ---- reset values, idle bus
    rd(A_ID, d);  check(d == 32'h4D44494F, "ID");
    rd(A_VER, d); check(d == 32'h00000100, "VERSION");
    rd(A_CFG, d); check(d == (32'h00002000 | DIV0), $sformatf("CFG reset %h", d));
    rd(A_ST, d);  check(d == 32'h00000400, $sformatf("STATUS reset %h", d));
    r0 = n_rise;
    wait_idle_us(5);
    check(n_rise == r0 && mdc == 1'b0 && mdio_t == 1'b1, "idle bus: MDC low, MDIO released");
    $display("TB_RES reset: ID, VERSION, CFG 0x%08h, STATUS 0x400, bus idle", 32'h00002000 | DIV0);

    // ---- clause 22
    cmd(2'b10, 0, 0, 1, 2, 0); cmd(2'b10, 0, 0, 1, 3, 0);
    cmd(2'b10, 0, 0, 5, 2, 0); cmd(2'b10, 0, 0, 9, 3, 0);
    for (int i = 0; i < 60; i++) begin
        int pas [3] = '{1, 5, 9};
        int pa, ra;
        pa = pas[$urandom_range(2)];
        ra = $urandom_range(31);
        cmd(2'b01, 0, 0, pa, ra, 16'($urandom));
        cmd(2'b10, 0, 0, pas[$urandom_range(2)], $urandom_range(31), 0);
        cmd(2'b10, 0, 0, pa, ra, 0);
    end
    for (int r = 0; r < 32; r++) begin
        check(u_phy1.r22[r] == x22(1, r) && u_phy5.r22[r] == x22(5, r) && u_phy9.r22[r] == x22(9, r),
              $sformatf("PHY register file c22 reg %0d", r));
    end
    $display("TB_RES c22: %0d commands, %0d reads checked; PHY1 %0d wr %0d rd, PHY5 %0d wr %0d rd, PHY9 %0d wr %0d rd",
             n_ops, n_rd_ok, u_phy1.n_wr22, u_phy1.n_rd22, u_phy5.n_wr22, u_phy5.n_rd22, u_phy9.n_wr22, u_phy9.n_rd22);

    // ---- nobody at address 7; clause 45 to the clause-22-only PHY
    r0 = u_phy1.n_frames + u_phy5.n_frames + u_phy9.n_frames;
    cmd(2'b10, 0, 0, 7, 1, 0);
    cmd(2'b01, 0, 0, 7, 1, 16'h1234);
    cmd(2'b11, 1, 1, 7, 1, 0, 16'h0002);
    cmd(2'b11, 1, 1, 9, 1, 0, 16'h0002);
    cmd(2'b11, 1, 0, 9, 3, 0);
    check(u_phy1.n_frames + u_phy5.n_frames + u_phy9.n_frames == r0, "frames to absent addresses answered");
    $display("TB_RES absent: %0d reads with TA_ERR, RDATA 0xFFFF, RD_VALID 0", n_ta_err);

    // ---- clause 45, separate frames
    for (int i = 0; i < 2; i++) begin
        int pa;
        pa = (i == 0) ? 1 : 5;
        for (int j = 0; j < 5; j++) begin
            int devs [5] = '{1, 3, 7, 30, 31};
            logic [15:0] a;
            a = 16'($urandom);
            cmd(2'b00, 1, 0, pa, devs[j], a);
            cmd(2'b01, 1, 0, pa, devs[j], 16'($urandom));
            cmd(2'b00, 1, 0, pa, devs[j], a + 16'd1);
            cmd(2'b11, 1, 0, pa, devs[j], 0);
            cmd(2'b00, 1, 0, pa, devs[j], a);
            cmd(2'b11, 1, 0, pa, devs[j], 0);
        end
    end
    // address registers are per MMD
    cmd(2'b00, 1, 0, 1, 1, 16'h0100);
    cmd(2'b00, 1, 0, 1, 3, 16'h0300);
    cmd(2'b11, 1, 0, 1, 1, 0);
    cmd(2'b11, 1, 0, 1, 3, 0);
    check(u_phy1.areg[1] == 16'h0100 && u_phy1.areg[3] == 16'h0300, "per-MMD address registers");
    // ADDR_FIRST
    for (int i = 0; i < 80; i++) begin
        int pa, dev;
        logic [15:0] a;
        pa = $urandom_range(1) ? 5 : 1;
        dev = $urandom_range(31);
        a = 16'($urandom);
        cmd(2'b01, 1, 1, pa, dev, 16'($urandom), a);
        cmd(2'b11, 1, 1, pa, dev, 0, a);
        cmd(2'b11, 1, 1, pa, $urandom_range(31), 0, 16'($urandom));
    end
    begin
        int bad;
        bad = 0;
        foreach (e45[k]) begin
            int pa, dev, a;
            a = k % 65536;
            dev = (k / 65536) % 32;
            pa = k / (65536 * 32);
            if (pa == 1 && u_phy1.rd45(dev, a) != e45[k]) bad++;
            if (pa == 5 && u_phy5.rd45(dev, a) != e45[k]) bad++;
        end
        check(bad == 0, "PHY register file c45");
        $display("TB_RES c45: %0d registers written and found in the PHY models; PHY1 %0d addr %0d wr %0d rd, PHY5 %0d addr %0d wr %0d rd",
                 e45.num(), u_phy1.n_addr45, u_phy1.n_wr45, u_phy1.n_rd45, u_phy5.n_addr45, u_phy5.n_wr45, u_phy5.n_rd45);
    end
    // post-read-increment-address
    cmd(2'b00, 1, 0, 5, 3, 16'h1000);
    for (int i = 0; i < 8; i++) cmd(2'b10, 1, 0, 5, 3, 0);
    check(u_phy5.areg[3] == 16'h1008, "post-read-increment address register");
    cmd(2'b11, 1, 0, 5, 3, 0);
    cmd(2'b10, 1, 1, 1, 7, 0, 16'hFFFF);           // ADDR_FIRST + increment, wraps
    check(u_phy1.areg[7] == 16'h0000, "post-read-increment wrap");
    $display("TB_RES pria: 9 post-read-increment reads, address 0x1000 -> 0x1008, wrap 0xFFFF -> 0");

    // ---- frame time, back to back
    r0 = n_rise;
    cmd(2'b10, 0, 0, 5, 1, 0);
    exp_cyc = (32 + 33) * 2 * (DIV0 + 1);
    check(n_rise - r0 == 65, $sformatf("MDC cycles per frame %0d", n_rise - r0));
    check(last_busy >= exp_cyc && last_busy <= exp_cyc + SYNC_STAGES + 4, $sformatf("busy %0d cycles", last_busy));
    $display("TB_RES frame: c22 read = %0d MDC cycles, busy %0d clk cycles (bits x 2(DIV+1) = %0d) = %0.2f us",
             n_rise - r0, last_busy, exp_cyc, last_busy * TCLK / 1000.0);
    r0 = n_rise;
    cmd(2'b11, 1, 1, 1, 1, 0, 16'h0007);
    check(n_rise - r0 == 130, $sformatf("MDC cycles ADDR_FIRST %0d", n_rise - r0));
    check(last_busy >= 2 * exp_cyc && last_busy <= 2 * exp_cyc + 2 * (SYNC_STAGES + 4),
          $sformatf("busy ADDR_FIRST %0d cycles", last_busy));
    $display("TB_RES frame: c45 ADDR_FIRST read = %0d MDC cycles, busy %0d clk cycles = %0.2f us",
             n_rise - r0, last_busy, last_busy * TCLK / 1000.0);
    // back to back: no pause between commands beyond the AXI accesses
    t0 = $time;
    for (int i = 0; i < 20; i++) rand_cmd(1'b1);
    $display("TB_RES back-to-back: 20 random commands in %0.1f us", ($time - t0) / 1000.0);

    // ---- divider sweep
    for (int i = 0; i < 7; i++) begin
        int divs [7] = '{1, 2, 4, 9, 49, 124, 255};
        int div;
        div = divs[i];
        if ((div + 1) * TCLK < 12.0) continue;      // half period below the 10 ns setup / hold
        set_cfg(div, 32, 0);
        r0 = n_rise;
        cmd(2'b01, 0, 0, 1, 4, 16'($urandom));
        cmd(2'b10, 0, 0, 1, 4, 0);
        cmd(2'b01, 1, 1, 5, 1, 16'($urandom), 16'($urandom));
        cmd(2'b11, 1, 1, 5, 1, 0, 16'($urandom));
        cmd(2'b10, 0, 0, 9, 2, 0);
        exp_cyc = 65 * 2 * (div + 1);
        check(last_busy >= exp_cyc && last_busy <= exp_cyc + SYNC_STAGES + 4, $sformatf("busy at DIV %0d", div));
        check(n_rise - r0 == 65 * 7, $sformatf("MDC cycles at DIV %0d: %0d", div, n_rise - r0));
        $display("TB_RES div: DIV %0d -> MDC %0.3f MHz (half period %0.1f ns), PHY delay up to %0.0f ns, 5 commands OK",
                 div, 1000.0 / (2.0 * (div + 1) * TCLK), (div + 1) * TCLK, u_phy1.tout_max);
    end
    set_cfg(DIV0, 32, 0);

    // ---- preamble length and suppression
    cmd(2'b10, 0, 0, 5, 2, 0);
    set_cfg(DIV0, 0, 0);
    r0 = u_phy1.n_frames;
    r1 = n_rise;
    cmd(2'b10, 0, 0, 5, 2, 0);
    check(u_phy5.last_pre == 1, $sformatf("PHY5 saw %0d ones before the frame (suppressed)", u_phy5.last_pre));
    check(n_rise - r1 == 33, "33 MDC cycles without preamble");
    for (int i = 0; i < 10; i++) begin
        cmd(2'b01, 1, 1, 5, 7, 16'($urandom), 16'($urandom));
        cmd(2'b11, 1, 1, 5, 7, 0, 16'($urandom));
    end
    cmd(2'b10, 0, 0, 1, 2, 0, 16'h0, 1'b0);
    rd(A_ST, st);
    check(st[3] && u_phy1.n_frames == r0, "PHY1 (full preamble required) ignores a suppressed frame");
    set_cfg(DIV0, 8, 0);
    cmd(2'b10, 0, 0, 5, 2, 0);
    check(u_phy5.last_pre == 9, $sformatf("PRE_LEN 8: PHY5 saw %0d ones", u_phy5.last_pre));
    set_cfg(DIV0, 32, 0);
    cmd(2'b10, 0, 0, 1, 2, 0);
    check(u_phy1.n_frames == r0 + 1 && u_phy1.last_pre >= 33, $sformatf("PHY1 answers with the full preamble again: %0d frames (before %0d), %0d ones", u_phy1.n_frames, r0, u_phy1.last_pre));
    $display("TB_RES preamble: PRE_LEN 0 (PHY5: 1 idle one seen, 33 MDC cycles per frame, 21 frames), PHY1 ignores it; PRE_LEN 8 -> 9 ones; 32 -> 33");

    // ---- free-running MDC
    set_cfg(DIV0, 32, 1);
    r0 = n_rise;
    wait_idle_us(20);
    r1 = n_rise - r0;
    exp_cyc = int'(20000.0 / (2.0 * (DIV0 + 1) * TCLK));
    check(r1 >= exp_cyc - 1 && r1 <= exp_cyc + 1, $sformatf("free-running MDC: %0d rising edges in 20 us", r1));
    for (int i = 0; i < 20; i++) rand_cmd(1'b1);
    set_cfg(DIV0, 32, 0);
    #500;
    r0 = n_rise;
    wait_idle_us(20);
    check(n_rise == r0 && mdc == 1'b0, "MDC stops low when MDC_FREE is cleared");
    $display("TB_RES free-run: %0d MDC rising edges in 20 us idle (%0.3f MHz), 20 commands, MDC stops low when cleared",
             r1, 1000.0 / (2.0 * (DIV0 + 1) * TCLK));

    // ---- hold-off
    hold <= 1'b1;
    #200;
    r0 = n_rise;
    wr(A_WD, 32'h0);
    wr(A_CMD, 32'h0002_0502);                   // c22 read PHY5 reg 2
    wait_idle_us(30);
    rd(A_ST, st);
    check(st[0] && st[8] && st[9] && n_rise == r0, $sformatf("held: status %h", st));
    hold <= 1'b0;
    do rd(A_ST, st); while (st[0]);
    rd(A_RD, d);
    check(st[1] && st[2] && d[15:0] == x22(5, 2) && n_rise - r0 == 65, "held command completes after hold");
    set_cfg(DIV0, 32, 0, 0, 1);                 // CFG.HOLD
    r0 = n_rise;
    wr(A_CMD, 32'h0002_0102);
    wait_idle_us(30);
    rd(A_ST, st);
    check(st[0] && st[8] && n_rise == r0, "held by CFG.HOLD");
    wr(A_CTL, 32'h1);                           // abort while held: no bus activity
    rd(A_ST, st);
    check(!st[0] && st[1] && st[5] && n_rise == r0, $sformatf("abort while held: status %h", st));
    set_cfg(DIV0, 32, 0);
    r0 = n_rise;
    cmd(2'b10, 0, 0, 1, 2, 0);
    check(n_rise - r0 == 65, "no resynchronisation after aborting a held command");
    // hold rising in the middle of a frame: the frame completes
    wr(A_CMD, 32'h0002_0102);
    #(20 * 2 * (DIV0 + 1) * TCLK);
    hold <= 1'b1;
    do rd(A_ST, st); while (st[0]);
    rd(A_RD, d);
    check(st[2] && d[15:0] == x22(1, 2), "a started frame ends normally under hold");
    hold <= 1'b0;
    // hold rising during the address frame of an ADDR_FIRST command: the data frame follows
    r0 = n_rise;
    wr(A_WD, 32'h0009_0000);
    wr(A_CMD, 32'h0007_050F);                   // c45 ADDR_FIRST read PHY5 dev 7 reg 9
    while (n_rise - r0 < 40) @(posedge mdc_phy);
    hold <= 1'b1;
    do rd(A_ST, st); while (st[0]);
    rd(A_RD, d);
    earg[5 * 32 + 7] = 16'h0009;
    check(st[2] && d[15:0] == x45(5, 7, 9) && n_rise - r0 == 130, "a started ADDR_FIRST command ends under hold");
    hold <= 1'b0;
    $display("TB_RES hold: input and CFG.HOLD block the start (0 MDC edges in 30 us), release starts it, abort while held = no bus activity, a running frame completes");

    // ---- abort in the middle of frames, resynchronisation
    chk_sh = 1'b0;
    r1 = u_phy1.ta_err + u_phy5.ta_err + u_phy9.ta_err;
    for (int i = 0; i < 12; i++) begin
        int nb;
        nb = (i % 2) ? $urandom_range(2, 125) : $urandom_range(2, 63);
        wr(A_WD, 32'h0003_0000);
        wr(A_CMD, (i % 2) ? 32'h0001_010F : 32'h0002_0502);   // c45 ADDR_FIRST read PHY1 dev 1 / c22 read PHY5
        r0 = n_rise;
        while (n_rise - r0 < nb) @(posedge mdc_phy);
        #($urandom_range(0, 300));
        wr(A_CTL, 32'h1);
        rd(A_ST, st);
        check(!st[0] && st[1] && st[5], $sformatf("aborted: status %h", st));
        #1000;
        chk_sh = 1'b1;
        r0 = n_rise;
        cmd(2'b10, 0, 0, 5, 2, 0);
        check(n_rise - r0 == 64 + 65, $sformatf("resync + frame: %0d MDC cycles", n_rise - r0));
        cmd(2'b11, 1, 1, 1, 1, 0, 16'h0003);
        chk_sh = 1'b0;
    end
    chk_sh = 1'b1;
    // a cut write-type frame looks like one with a bad turnaround to a PHY that decoded its
    // header: expected here, not counted as an error
    r1 = u_phy1.ta_err + u_phy5.ta_err + u_phy9.ta_err - r1;
    u_phy1.ta_err = 0; u_phy5.ta_err = 0; u_phy9.ta_err = 0;
    $display("TB_RES abort: %0d cut frames seen by a PHY as frames with a bad turnaround", r1);
    $display("TB_RES abort: 12 aborts at random bits (incl. while the PHY drives): bus released at once, next frame after 64 released MDC cycles, data correct, no contention");

    // ---- bit-bang mode
    chk_mdc = 1'b0;
    chk_sh = 1'b0;
    wr(A_BB, 32'h8000_0002);                    // BB_EN, MDC low, released
    wr(A_CMD, 32'h0002_0502);
    rd(A_ST, st);
    check(st[6] && !st[0], "command ignored in bit-bang mode");
    wr(A_ST, 32'h40);
    begin
        logic [31:0] fr;
        logic [15:0] got;
        bit ta;
        fr = {2'b01, 2'b10, 5'd5, 5'd3, 2'b11, 16'hFFFF};     // c22 read PHY5 reg 3
        for (int i = 0; i < 32 + 32 + 1; i++) begin
            bit drive, v;
            if (i < 32) begin drive = 1; v = 1; end
            else if (i - 32 < 14) begin drive = 1; v = fr[31 - (i - 32)]; end
            else begin drive = 0; v = 1; end
            wr(A_BB, 32'h8000_0000 | (32'(drive) << 2) | (32'(v) << 1));          // MDC low, data
            #400;
            wr(A_BB, 32'h8000_0001 | (32'(drive) << 2) | (32'(v) << 1));          // MDC high
            #400;
            wr(A_BB, 32'h8000_0000 | (32'(drive) << 2) | (32'(v) << 1));          // MDC low
            #400;
            // the PHY changes MDIO after a rising edge: what is read now is the next bit
            if (i >= 32 + 14 && i < 32 + 31) begin
                rd(A_BB, d);
                if (i == 32 + 14) ta = d[8];
                else got = {got[14:0], d[8]};
            end
        end
        check(ta == 1'b0 && got == x22(5, 3), $sformatf("bit-bang c22 read: ta %b data %h want %h", ta, got, x22(5, 3)));
        $display("TB_RES bitbang: c22 read of PHY5 reg 3 by register bits = %h (TA 0), CMD ignored while BB_EN", got);
    end
    wr(A_BB, 32'h0000_0000);
    chk_mdc = 1'b1;
    chk_sh = 1'b1;
    t_r = 0; t_f = 0;
    cmd(2'b10, 0, 0, 1, 3, 0);

    // ---- interrupt
    set_cfg(DIV0, 32, 0, 1);
    repeat (2) @(posedge clk);
    check(irq == 1'b1, "IRQ_EN with DONE set raises irq");
    wr(A_ST, 32'h2);
    repeat (2) @(posedge clk);
    check(irq == 1'b0, "DONE w1c clears irq");
    wr(A_CMD, 32'h0002_0102);
    @(posedge irq);
    rd(A_ST, st);
    check(!st[0] && st[1] && st[2], "irq at the end of the command");
    wr(A_ST, 32'h2);
    set_cfg(DIV0, 32, 0, 0);
    cmd(2'b10, 0, 0, 1, 3, 0);
    repeat (2) @(posedge clk);
    check(irq == 1'b0, "no irq with IRQ_EN 0");
    $display("TB_RES irq: level = DONE & IRQ_EN, cleared by DONE w1c");

    // ---- CMD while busy
    wr(A_WD, 32'h0);
    wr(A_CMD, 32'h0002_0102);
    wr(A_CMD, 32'h0003_0501);                   // ignored
    do rd(A_ST, st); while (st[0]);
    rd(A_RD, d);
    check(st[6] && st[2] && d[15:0] == x22(1, 2), "CMD while busy ignored, CMD_IGN set");
    rd(A_CMD, d);
    check(d == 32'h0002_0102, "CMD reads the running command");
    wr(A_ST, 32'h40);
    rd(A_ST, st);
    check(!st[6], "CMD_IGN w1c");
    $display("TB_RES busy: CMD written while BUSY ignored, CMD_IGN set and cleared");

    // ---- bus error: MDIO held low during a write
    stuck_low <= 1'b1;
    wr(A_WD, 32'h0000_5555);
    wr(A_CMD, 32'h0001_0701);
    do rd(A_ST, st); while (st[0]);
    stuck_low <= 1'b0;
    check(st[4], "BUS_ERR with MDIO stuck low");
    cmd(2'b10, 0, 0, 1, 2, 0);
    $display("TB_RES bus-error: MDIO stuck low -> BUS_ERR, cleared by the next command");

    // ---- AXI corner cases: address before data, partial strobes
    @(posedge clk); awaddr <= A_WD; awvalid <= 1'b1;
    repeat (3) @(posedge clk);
    wdata <= 32'hABCD_1234; wstrb <= 4'hF; wvalid <= 1'b1;
    do @(posedge clk); while (!awready);
    awvalid <= 1'b0; wvalid <= 1'b0;
    while (!bvalid) @(posedge clk);
    rd(A_WD, d);
    check(d == 32'hABCD_1234, "write with address first");
    wr(A_CFG, 32'h0001_FFFF, 4'b0100);          // byte 2 only: MDC_FREE
    rd(A_CFG, d);
    check(d == (32'h0001_2000 | DIV0), $sformatf("CFG partial write %h", d));
    set_cfg(DIV0, 32, 0);
    rd(12'h024, d);
    check(d == 0, "unused address reads 0");
    $display("TB_RES axi: address-before-data write, byte strobes, unused address");

    // ---- random soak
    for (int i = 0; i < SOAK; i++) rand_cmd();
    $display("TB_RES soak: %0d random commands (clause 22 / 45, all OPs, ADDR_FIRST, absent addresses)", SOAK);

    // ---- summary
    check(contention == 0, "bus contention");
    check(od_err == 0, "open-drain drove a 1");
    check(mdc_err == 0, "MDC timing");
    check(sh_err == 0, "MDIO setup / hold");
    check(u_phy1.ta_err + u_phy5.ta_err + u_phy9.ta_err == 0, "write turnaround seen by the PHYs");
    $display("TB_RES totals: %0d commands, %0d reads checked, %0d no-answer reads, contention %0d, MDC errors %0d, setup/hold errors %0d, min setup %0.1f ns, min hold %0.1f ns",
             n_ops, n_rd_ok, n_ta_err, contention, mdc_err, sh_err, min_setup, min_hold);
    $display("TB_RES phys: PHY1 %0d frames, PHY5 %0d, PHY9 %0d", u_phy1.n_frames, u_phy5.n_frames, u_phy9.n_frames);
    if (errors == 0) $display("TB_PASS"); else $display("TB_FAIL %0d", errors);
    $finish;
end

initial begin
    #(500ms);
    $display("TB_FAIL timeout");
    $finish;
end

endmodule
