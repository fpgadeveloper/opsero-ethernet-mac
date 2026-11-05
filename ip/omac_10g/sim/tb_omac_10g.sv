// SPDX-License-Identifier: MIT
//
// tb_omac_10g - two omac_10g (A and B) connected back to back through two
// bit-level channel models (tb_gt_chan: random block phase, gearbox slip with
// latency, error injection). A and B run on clocks 100 ppm apart; each
// receiver runs on the far end's TX clock (the recovered clock), so the RX
// clock crossing of both IPs is exercised.
// Plusargs:
//   +mode=<frames|errors|pause|fault|hiber|watchdog>
//   +fa=<file> +fb=<file>      frames A sends / B sends ("len gap abort_beat under_beat hex")
//   +oa=<file> +ob=<file>      frames received by A / B ("user hex")
//   +cap=<file> +capn=<n>      A's transmitted 66-bit blocks ("hdr data"), first n after link up
//   +gap=<0..100>              (driver) unused, gaps come from the frame files
// Results: TB_* lines (link times, event counts, mode-specific measurements),
// TB_DONE at the end.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1fs
`default_nettype none

module tb_omac_10g #(
    parameter int SPEED       = 10,
    parameter int A_TX_PAD    = 1,
    parameter int B_MAX_FRAME = 9600,
    parameter int WD          = 2097152
);

`include "tb_util.svh"

localparam realtime PA = (SPEED == 25) ? 2.56 : 6.4;
localparam realtime PB = PA * 1.0001;

logic clk_a = 1'b0, clk_b = 1'b0;
always #(PA / 2) clk_a = ~clk_a;
always #(PB / 2) clk_b = ~clk_b;

logic rst_a = 1'b1, rst_b = 1'b1;
logic gt_ready = 1'b0;

// ---------------- DUT ports ----------------
logic [63:0] a_s_tdata, b_s_tdata;
logic [7:0]  a_s_tkeep, b_s_tkeep;
logic        a_s_tvalid = 1'b0, b_s_tvalid = 1'b0, a_s_tlast, b_s_tlast;
logic [0:0]  a_s_tuser = '0, b_s_tuser = '0;
wire         a_s_tready, b_s_tready;
wire  [63:0] a_m_tdata, b_m_tdata;
wire  [7:0]  a_m_tkeep, b_m_tkeep;
wire         a_m_tvalid, b_m_tvalid, a_m_tlast, b_m_tlast;
wire  [0:0]  a_m_tuser, b_m_tuser;

logic        a_tx_fault = 1'b0, b_tx_fault = 1'b0;
logic        a_honour = 1'b0, b_honour = 1'b0;
logic        a_psend = 1'b0, b_psend = 1'b0;
logic [15:0] a_pq = 16'd100, b_pq = 16'd100, a_pref = 16'd0, b_pref = 16'd0;
localparam logic [47:0] MAC_a = 48'h01_EF_CD_AB_00_02;   // 02:00:ab:cd:ef:01
localparam logic [47:0] MAC_b = 48'h02_EF_CD_AB_00_02;

wire [1:0]  a_tx_hdr, b_tx_hdr, a_rx_hdr, b_rx_hdr;
wire [63:0] a_tx_data, b_tx_data, a_rx_data, b_rx_data;
wire        a_rx_valid, b_rx_valid, a_slip, b_slip;

// status / events, bundled per DUT for the counters below
wire        a_link, b_link, a_lock, b_lock, a_hiber, b_hiber, a_lf, b_lf, a_rf, b_rf, a_preq, b_preq;
wire [15:0] a_pquanta, b_pquanta;
wire        a_pact, b_pact;
wire [11:0] a_ev, b_ev;
wire        a_wd, b_wd;
wire [2:0]  a_lb, b_lb;

`define OMAC_INST(X, CLK, RCLK, RST, PAD, MAXF) \
omac_10g #(.SPEED(SPEED), .TX_PAD(PAD), .MAX_FRAME(MAXF), .RX_WATCHDOG(WD)) dut_``X ( \
    .clk(CLK), .rst(RST), \
    .s_axis_tx_tdata(X``_s_tdata), .s_axis_tx_tkeep(X``_s_tkeep), .s_axis_tx_tvalid(X``_s_tvalid), \
    .s_axis_tx_tready(X``_s_tready), .s_axis_tx_tlast(X``_s_tlast), .s_axis_tx_tuser(X``_s_tuser), \
    .m_axis_rx_tdata(X``_m_tdata), .m_axis_rx_tkeep(X``_m_tkeep), .m_axis_rx_tvalid(X``_m_tvalid), \
    .m_axis_rx_tlast(X``_m_tlast), .m_axis_rx_tuser(X``_m_tuser), \
    .ctl_tx_enable(1'b1), .ctl_rx_enable(1'b1), .ctl_loopback(1'b0), .ctl_tx_fault(X``_tx_fault), \
    .ctl_pause_tx_honour(X``_honour), .ctl_tx_pause_send(X``_psend), .ctl_tx_pause_quanta(X``_pq), \
    .ctl_tx_pause_refresh(X``_pref), .ctl_mac_addr(MAC_``X), \
    .stat_link_up(X``_link), .stat_block_lock(X``_lock), .stat_hi_ber(X``_hiber), \
    .stat_local_fault(X``_lf), .stat_remote_fault(X``_rf), .stat_rx_pause_req(X``_preq), \
    .stat_rx_pause_quanta(X``_pquanta), .stat_tx_pause_active(X``_pact), \
    .ev_tx_frame(X``_ev[0]), .ev_tx_pause(X``_ev[1]), .ev_tx_underflow(X``_ev[2]), .ev_tx_abort(X``_ev[3]), \
    .ev_rx_frame_good(X``_ev[4]), .ev_rx_frame_bad(X``_ev[5]), .ev_rx_fcs_error(X``_ev[6]), \
    .ev_rx_runt(X``_ev[7]), .ev_rx_oversize(X``_ev[8]), .ev_rx_pause(X``_ev[9]), \
    .ev_rx_bad_block(X``_ev[10]), .ev_rx_sequence_error(X``_ev[11]), \
    .gt_tx_ready(gt_ready), .gt_tx_hdr(X``_tx_hdr), .gt_tx_data(X``_tx_data), .gt_loopback(X``_lb), \
    .gt_rx_clk(RCLK), .gt_rx_ready(gt_ready), .gt_rx_valid(X``_rx_valid), .gt_rx_hdr(X``_rx_hdr), \
    .gt_rx_data(X``_rx_data), .gt_rx_slip(X``_slip), .gt_rx_reset_req(X``_wd));

`OMAC_INST(a, clk_a, clk_b, rst_a, A_TX_PAD, 9600)
`OMAC_INST(b, clk_b, clk_a, rst_b, 1, B_MAX_FRAME)

// A -> B in clk_a (B's recovered clock), B -> A in clk_b
tb_gt_chan ch_ab (.clk(clk_a), .tx_hdr(a_tx_hdr), .tx_data(a_tx_data), .rx_slip(b_slip),
                  .rx_hdr(b_rx_hdr), .rx_data(b_rx_data), .rx_valid(b_rx_valid));
tb_gt_chan ch_ba (.clk(clk_b), .tx_hdr(b_tx_hdr), .tx_data(b_tx_data), .rx_slip(a_slip),
                  .rx_hdr(a_rx_hdr), .rx_data(a_rx_data), .rx_valid(a_rx_valid));

// ---------------- event counters ----------------
int cnt_a [12], cnt_b [12];
bit count_en = 1'b0;
int a_wd_n = 0, b_wd_n = 0;
logic a_wd_d = 1'b0, b_wd_d = 1'b0;
always @(posedge clk_a) begin
    if (count_en) for (int i = 0; i < 12; i++) if (a_ev[i]) cnt_a[i]++;
    if (a_wd && !a_wd_d) a_wd_n++;
    a_wd_d <= a_wd;
end
always @(posedge clk_b) begin
    if (count_en) for (int i = 0; i < 12; i++) if (b_ev[i]) cnt_b[i]++;
    if (b_wd && !b_wd_d) b_wd_n++;
    b_wd_d <= b_wd;
end

task automatic print_counts();
    $display("TB_CNT_A txf=%0d txp=%0d und=%0d abt=%0d good=%0d bad=%0d fcs=%0d runt=%0d over=%0d rxp=%0d badblk=%0d seq=%0d",
             cnt_a[0], cnt_a[1], cnt_a[2], cnt_a[3], cnt_a[4], cnt_a[5], cnt_a[6], cnt_a[7], cnt_a[8], cnt_a[9], cnt_a[10], cnt_a[11]);
    $display("TB_CNT_B txf=%0d txp=%0d und=%0d abt=%0d good=%0d bad=%0d fcs=%0d runt=%0d over=%0d rxp=%0d badblk=%0d seq=%0d",
             cnt_b[0], cnt_b[1], cnt_b[2], cnt_b[3], cnt_b[4], cnt_b[5], cnt_b[6], cnt_b[7], cnt_b[8], cnt_b[9], cnt_b[10], cnt_b[11]);
endtask

// ---------------- TX drivers ----------------
typedef struct { int gap; int abort_beat; int under_beat; byte unsigned b[$]; } tframe_t;
tframe_t txq_a [$], txq_b [$];
bit tx_go = 1'b0;
bit tx_cont_b = 1'b0;          // B sends filler frames continuously (pause test)
int tx_done_a = 0, tx_done_b = 0;

task automatic load_frames(string fn, ref tframe_t q[$]);
    integer fd, r, len;
    string hex;
    tframe_t f;
    fd = $fopen(fn, "r");
    if (fd == 0) return;
    while (!$feof(fd)) begin
        r = $fscanf(fd, "%d %d %d %d %s\n", len, f.gap, f.abort_beat, f.under_beat, hex);
        if (r != 5) break;
        tb_hex2bytes(hex, f.b);
        q.push_back(f);
    end
    $fclose(fd);
endtask

`define TX_DRIVER(X, CLK, CONT) \
initial begin : drv_``X \
    tframe_t f; int nb, i; \
    X``_s_tvalid = 1'b0; \
    wait (tx_go); \
    while (txq_``X.size() > 0 || CONT) begin \
        if (txq_``X.size() > 0) f = txq_``X.pop_front(); \
        else begin f.gap = 3; f.abort_beat = -1; f.under_beat = -1; f.b.delete(); \
                   for (int k = 0; k < 200; k++) f.b.push_back(8'(k)); end \
        repeat (f.gap) @(posedge CLK); \
        nb = (f.b.size() + 7) / 8; \
        for (int bt = 0; bt < nb; bt++) begin \
            if (bt == f.under_beat) begin \
                X``_s_tvalid <= 1'b0; \
                repeat (3) @(posedge CLK); \
            end \
            X``_s_tvalid <= 1'b1; \
            X``_s_tlast  <= (bt == nb - 1); \
            X``_s_tuser  <= (bt == f.abort_beat); \
            X``_s_tdata  <= 'x; \
            X``_s_tkeep  <= '0; \
            for (int k = 0; k < 8; k++) begin \
                i = bt * 8 + k; \
                if (i < f.b.size()) begin X``_s_tdata[8*k +: 8] <= f.b[i]; X``_s_tkeep[k] <= 1'b1; end \
            end \
            do @(posedge CLK); while (!X``_s_tready); \
        end \
        X``_s_tvalid <= 1'b0; \
        X``_s_tuser  <= 1'b0; \
        tx_done_``X++; \
    end \
end

`TX_DRIVER(a, clk_a, 1'b0)
`TX_DRIVER(b, clk_b, tx_cont_b)

// ---------------- RX monitors ----------------
int rx_n_a = 0, rx_n_b = 0, keep_err = 0, ctrl_seen = 0;
integer fo_a = 0, fo_b = 0;

`define RX_MON(X, CLK) \
initial begin : mon_``X \
    byte unsigned q[$]; int nk; bit seen_last; \
    forever begin \
        @(posedge CLK); \
        if (X``_m_tvalid) begin \
            nk = 0; seen_last = 1'b0; \
            for (int k = 0; k < 8; k++) begin \
                if (X``_m_tkeep[k]) begin \
                    if (seen_last) keep_err++; \
                    q.push_back(X``_m_tdata[8*k +: 8]); nk++; \
                end else seen_last = 1'b1; \
            end \
            if (nk == 0 || (!X``_m_tlast && nk != 8)) keep_err++; \
            if (X``_m_tlast) begin \
                if (q.size() >= 14 && q[12] == 8'h88 && q[13] == 8'h08) ctrl_seen++; \
                if (fo_``X != 0) $fdisplay(fo_``X, "%0d %s", X``_m_tuser, tb_bytes2hex(q)); \
                rx_n_``X++; \
                q.delete(); \
            end \
        end \
    end \
end

`RX_MON(a, clk_a)
`RX_MON(b, clk_b)

// ---------------- TX capture of A (66-bit blocks) ----------------
integer fcap = 0;
int     capn = 0, capd = 0;
bit     cap_en = 1'b0;
always @(posedge clk_a) begin
    if (cap_en && fcap != 0 && capd < capn) begin
        $fdisplay(fcap, "%0d %016x", a_tx_hdr, a_tx_data);
        capd++;
    end
end

// ---------------- helpers ----------------
time t0;
task automatic wait_link(output int cyc_a, output int cyc_b);
    int n;
    n = 0; cyc_a = -1; cyc_b = -1;
    while ((cyc_a < 0 || cyc_b < 0) && n < 400000) begin
        @(posedge clk_a);
        n++;
        if (cyc_a < 0 && a_link) cyc_a = n;
        if (cyc_b < 0 && b_link) cyc_b = n;
    end
endtask

// high periods of B's stat_rx_pause_req (in clk_b cycles) and B's frame starts
// while it was high for more than 32 cycles
int pz_len [$];
int pz_cur = 0;
int starts_in_pause = 0, starts_total = 0;
always @(posedge clk_b) begin
    if (b_preq) pz_cur++;
    else if (pz_cur != 0) begin
        pz_len.push_back(pz_cur);
        pz_cur = 0;
    end
    if ((dut_b.u_mac_tx.xc == 8'h01 && dut_b.u_mac_tx.xd[7:0] == 8'hFB) ||
        (dut_b.u_mac_tx.xc == 8'h1F && dut_b.u_mac_tx.xd[39:32] == 8'hFB)) begin
        starts_total++;
        if (pz_cur > 32) starts_in_pause++;
    end
end

// ---------------- main ----------------
initial begin
    string mode, fa, fb, oa, ob, cap;
    int la, lb, n, t_set, t_clr, ok;
    if (!$value$plusargs("mode=%s", mode)) mode = "frames";
    if ($value$plusargs("fa=%s", fa)) load_frames(fa, txq_a);
    if ($value$plusargs("fb=%s", fb)) load_frames(fb, txq_b);
    if ($value$plusargs("oa=%s", oa)) fo_a = $fopen(oa, "w");
    if ($value$plusargs("ob=%s", ob)) fo_b = $fopen(ob, "w");
    if ($value$plusargs("cap=%s", cap)) fcap = $fopen(cap, "w");
    if (!$value$plusargs("capn=%d", capn)) capn = 0;
    $display("TB_INFO mode=%s frames_a=%0d frames_b=%0d phase_ab=%0d phase_ba=%0d", mode, txq_a.size(),
             txq_b.size(), ch_ab.phase, ch_ba.phase);

    repeat (10) @(posedge clk_a);
    rst_a <= 1'b0;
    rst_b <= 1'b0;
    repeat (20) @(posedge clk_a);
    gt_ready <= 1'b1;

    if (mode == "watchdog") begin
        ch_ab.kill = 1'b1;
        repeat (WD * 3 + 1000) @(posedge clk_b);
        $display("TB_WD b_pulses=%0d a_pulses=%0d b_lock=%0d a_lock=%0d", b_wd_n, a_wd_n, b_lock, a_lock);
        $display("TB_DONE");
        $finish;
    end

    wait_link(la, lb);
    $display("TB_LINK a=%0d b=%0d slips_ab=%0d slips_ba=%0d", la, lb, ch_ab.n_slip, ch_ba.n_slip);
    if (la < 0 || lb < 0) begin
        $display("TB_FAIL no link");
        $display("TB_DONE");
        $finish;
    end
    repeat (50) @(posedge clk_a);
    count_en = 1'b1;
    cap_en   = 1'b1;

    if (mode == "frames" || mode == "errors") begin
        if (mode == "errors") ch_ba.dflip = 40;
        tx_go = 1'b1;
        n = 0;
        while ((txq_a.size() > 0 || txq_b.size() > 0 || a_s_tvalid || b_s_tvalid) && n < 4000000) begin
            @(posedge clk_a); n++;
        end
        repeat (2000) @(posedge clk_a);
        $display("TB_INJ dflip_ba=%0d", ch_ba.n_dflip);
    end else if (mode == "pause") begin
        // B keeps sending filler frames and honours PAUSE
        b_honour  = 1'b1;
        tx_cont_b = 1'b1;
        tx_go     = 1'b1;
        repeat (500) @(posedge clk_a);
        // 1: XOFF 100 quanta, no refresh; request held longer than the pause
        a_pq = 16'd100; a_pref = 16'd0;
        a_psend = 1'b1; repeat (3000) @(posedge clk_a); a_psend = 1'b0;
        repeat (2000) @(posedge clk_a);
        // 2: XOFF 65535 quanta, XON after 2000 cycles
        a_pq = 16'd65535;
        a_psend = 1'b1; repeat (2000) @(posedge clk_a); a_psend = 1'b0;
        repeat (2000) @(posedge clk_a);
        // 3: XOFF 200 quanta refreshed every 100 quanta for 10000 cycles, then XON
        a_pq = 16'd200; a_pref = 16'd100;
        a_psend = 1'b1; repeat (10000) @(posedge clk_a); a_psend = 1'b0;
        repeat (2000) @(posedge clk_a);
        tx_cont_b = 1'b0;
        repeat (2000) @(posedge clk_a);
        foreach (pz_len[i]) $display("TB_PAUSE i=%0d cycles=%0d", i, pz_len[i]);
        $display("TB_PSTARTS total=%0d in_pause=%0d", starts_total, starts_in_pause);
    end else if (mode == "fault") begin
        // 1: B sends Local Fault -> A local fault, A sends RF -> B remote fault
        b_tx_fault = 1'b1;
        repeat (3000) @(posedge clk_a);
        $display("TB_FAULT1 a_lf=%0d a_rf=%0d a_link=%0d b_lf=%0d b_rf=%0d b_link=%0d a_out_rf=%0d",
                 a_lf, a_rf, a_link, b_lf, b_rf, b_link,
                 dut_a.t_xc == 8'h11 && dut_a.t_xd == {8'h02, 16'h0, 8'h9C, 8'h02, 16'h0, 8'h9C});
        b_tx_fault = 1'b0;
        wait_link(la, lb);
        $display("TB_FAULT1R a=%0d b=%0d", la, lb);
        // 2: A's receiver broken (all headers invalid B->A): A local fault from its own PCS,
        //    A sends RF, B (remote fault) sends idles although frames are offered
        tx_cont_b = 1'b1;
        tx_go = 1'b1;
        ch_ba.kill = 1'b1;
        repeat (3000) @(posedge clk_a);
        ok = 1;
        for (int i = 0; i < 500; i++) begin
            @(posedge clk_b);
            if (!(dut_b.t_xc == 8'hFF && dut_b.t_xd == {8{8'h07}})) ok = 0;
        end
        $display("TB_FAULT2 a_lock=%0d a_lf=%0d b_rf=%0d b_link=%0d b_idles=%0d b_tready=%0d",
                 a_lock, a_lf, b_rf, b_link, ok, b_s_tready);
        ch_ba.kill = 1'b0;
        tx_cont_b = 1'b0;
        wait_link(la, lb);
        $display("TB_FAULT2R a=%0d b=%0d", la, lb);
    end else if (mode == "hiber") begin
        // 1: low error rate, no hi_ber
        ch_ab.hdr_rate = 4000;
        ok = 1;
        for (int i = 0; i < 3 * 19532; i++) begin @(posedge clk_b); if (b_hiber) ok = 0; end
        $display("TB_HIBER1 hdr_errs=%0d no_hiber=%0d lock=%0d", ch_ab.n_hdr, ok, b_lock);
        // 2: high rate, hi_ber within a window
        ch_ab.hdr_rate = 150;
        t_set = -1;
        for (int i = 0; i < 3 * 19532 && t_set < 0; i++) begin @(posedge clk_b); if (b_hiber) t_set = i; end
        repeat (100) @(posedge clk_b);
        $display("TB_HIBER2 set_after=%0d b_link=%0d b_lf=%0d a_rf=%0d lock=%0d", t_set, b_link, b_lf, a_rf, b_lock);
        // 3: errors off, hi_ber clears
        ch_ab.hdr_rate = 0;
        t_clr = -1;
        for (int i = 0; i < 3 * 19532 && t_clr < 0; i++) begin @(posedge clk_b); if (!b_hiber) t_clr = i; end
        wait_link(la, lb);
        $display("TB_HIBER3 clr_after=%0d link_a=%0d link_b=%0d", t_clr, la, lb);
        // 4: a burst of 20 invalid headers: lock lost and re-acquired
        ch_ab.burst = 20;
        t_clr = -1;
        for (int i = 0; i < 2000 && t_clr < 0; i++) begin @(posedge clk_b); if (!b_lock) t_clr = i; end
        wait_link(la, lb);
        $display("TB_HIBER4 lock_lost_after=%0d relink_a=%0d relink_b=%0d", t_clr, la, lb);
    end
    print_counts();
    $display("TB_RX a=%0d b=%0d keep_err=%0d ctrl_seen=%0d tx_done_a=%0d tx_done_b=%0d",
             rx_n_a, rx_n_b, keep_err, ctrl_seen, tx_done_a, tx_done_b);
    if (fo_a) $fclose(fo_a);
    if (fo_b) $fclose(fo_b);
    if (fcap) $fclose(fcap);
    $display("TB_DONE");
    $finish;
end

endmodule
