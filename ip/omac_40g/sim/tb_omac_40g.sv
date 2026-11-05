// SPDX-License-Identifier: MIT
//
// tb_omac_40g - two omac_40g (A and B) back to back, four lanes each way. Every
// lane goes through a block delay (lane skew), a lane permutation (physical
// order != PCS lane order) and a bit-level channel + gearbox model (tb_gt_chan,
// from omac_10g: random 66-bit phase, slip with latency, error injection). A and
// B run on clocks 100 ppm apart; each receiver lane runs on its own recovered
// clock: the far end's TX clock delayed by a random phase per lane.
// Plusargs:
//   +mode=<frames|errors|overflow|perms|skew|lanefail|hiber|pause|fault|rate|watchdog>
//   +fa=<file> +fb=<file>      frames A sends / B sends ("len gap abort_beat under_beat hex")
//   +oa=<file> +ob=<file>      frames received by A / B ("user hex")
//   +cap=<file> +capn=<n>      the four lanes of A -> B as B receives them (physical lane order,
//                              after skew and permutation): "h0 d0 h1 d1 h2 d2 h3 d3" per cycle
//   +perm=<0..23> +skew=<s0,s1,s2,s3>  A -> B permutation / skew (blocks per PCS lane)
//   +nper=<n>                  perms mode: frames per permutation
// Results: TB_* lines; TB_DONE at the end.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1fs
`default_nettype none

module tb_omac_40g #(
    parameter int AM_PERIOD   = 16384,
    parameter int A_TX_PAD    = 1,
    parameter int B_MAX_FRAME = 9600,
    parameter int WD          = 2097152,
    parameter int DESKEW_MAX  = 32,
    parameter int BER_TIMER   = 195313
);

`include "tb_util.svh"

localparam realtime PA = 6.4;
localparam realtime PB = PA * 1.0001;

logic clk_a = 1'b0, clk_b = 1'b0;
always #(PA / 2) clk_a = ~clk_a;
always #(PB / 2) clk_b = ~clk_b;

// recovered clocks: B's lane q = clk_a delayed by ph_b[q]; A's lane q = clk_b delayed
realtime ph_b [4], ph_a [4];
logic [3:0] rck_b = '0, rck_a = '0;
initial for (int q = 0; q < 4; q++) begin
    ph_b[q] = PA * $urandom_range(999) / 1000.0;
    ph_a[q] = PB * $urandom_range(999) / 1000.0;
end
for (genvar q = 0; q < 4; q++) begin : g_rck
    always @(clk_a) rck_b[q] <= #(ph_b[q]) clk_a;
    always @(clk_b) rck_a[q] <= #(ph_a[q]) clk_b;
end

logic rst_a = 1'b1, rst_b = 1'b1;
logic gt_ready = 1'b0;

// ---------------- DUT ports ----------------
logic [255:0] a_s_tdata, b_s_tdata;
logic [31:0]  a_s_tkeep, b_s_tkeep;
logic         a_s_tvalid = 1'b0, b_s_tvalid = 1'b0, a_s_tlast, b_s_tlast;
logic [0:0]   a_s_tuser = '0, b_s_tuser = '0;
wire          a_s_tready, b_s_tready;
wire  [255:0] a_m_tdata, b_m_tdata;
wire  [31:0]  a_m_tkeep, b_m_tkeep;
wire          a_m_tvalid, b_m_tvalid, a_m_tlast, b_m_tlast;
wire  [0:0]   a_m_tuser, b_m_tuser;

logic        a_tx_fault = 1'b0, b_tx_fault = 1'b0;
logic        a_honour = 1'b0, b_honour = 1'b0;
logic        a_psend = 1'b0, b_psend = 1'b0;
logic [15:0] a_pq = 16'd100, b_pq = 16'd100, a_pref = 16'd0, b_pref = 16'd0;
localparam logic [47:0] MAC_a = 48'h01_EF_CD_AB_00_02;   // 02:00:ab:cd:ef:01
localparam logic [47:0] MAC_b = 48'h02_EF_CD_AB_00_02;

wire [7:0]   a_tx_hdr, b_tx_hdr;
wire [255:0] a_tx_data, b_tx_data;
logic [7:0]  a_rx_hdr, b_rx_hdr;
logic [255:0] a_rx_data, b_rx_data;
logic [3:0]  a_rx_valid, b_rx_valid;
wire  [3:0]  a_slip, b_slip;

wire        a_link, b_link, a_lock, b_lock, a_hiber, b_hiber, a_lf, b_lf, a_rf, b_rf, a_preq, b_preq;
wire [15:0] a_pquanta, b_pquanta;
wire        a_pact, b_pact;
wire [14:0] a_ev, b_ev;
wire [3:0]  a_bip, b_bip;
wire [3:0]  a_llock, b_llock, a_laml, b_laml;
wire [7:0]  a_lmap, b_lmap;
wire [6:0]  a_lskew, b_lskew;
wire        a_wd, b_wd;
wire [2:0]  a_lb, b_lb;

`define OMAC_INST(X, CLK, RCLK, RST, PAD, MAXF) \
omac_40g #(.TX_PAD(PAD), .MAX_FRAME(MAXF), .RX_WATCHDOG(WD), .AM_PERIOD(AM_PERIOD), .DESKEW_MAX(DESKEW_MAX), \
           .LANE_FIFO_DEPTH((DESKEW_MAX + 16 <= 64) ? 64 : 128), .BER_TIMER_CLKS(BER_TIMER)) dut_``X ( \
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
    .stat_lane_block_lock(X``_llock), .stat_lane_am_lock(X``_laml), .stat_lane_map(X``_lmap), \
    .stat_lane_skew(X``_lskew), \
    .ev_tx_frame(X``_ev[0]), .ev_tx_pause(X``_ev[1]), .ev_tx_underflow(X``_ev[2]), .ev_tx_abort(X``_ev[3]), \
    .ev_rx_frame_good(X``_ev[4]), .ev_rx_frame_bad(X``_ev[5]), .ev_rx_fcs_error(X``_ev[6]), \
    .ev_rx_runt(X``_ev[7]), .ev_rx_oversize(X``_ev[8]), .ev_rx_pause(X``_ev[9]), \
    .ev_rx_bad_block(X``_ev[10]), .ev_rx_sequence_error(X``_ev[11]), \
    .ev_rx_bip_error(X``_bip), .ev_rx_overflow(X``_ev[12]), .ev_rx_skew_fail(X``_ev[13]), \
    .gt_tx_ready(gt_ready), .gt_tx_hdr(X``_tx_hdr), .gt_tx_data(X``_tx_data), .gt_loopback(X``_lb), \
    .gt_rx_clk(RCLK), .gt_rx_ready(gt_ready), .gt_rx_valid(X``_rx_valid), .gt_rx_hdr(X``_rx_hdr), \
    .gt_rx_data(X``_rx_data), .gt_rx_slip(X``_slip), .gt_rx_reset_req(X``_wd));

`OMAC_INST(a, clk_a, rck_a, rst_a, A_TX_PAD, 9600)
`OMAC_INST(b, clk_b, rck_b, rst_b, 1, B_MAX_FRAME)
assign a_ev[14] = 1'b0;
assign b_ev[14] = 1'b0;

// ---------------- lanes: skew (block delay), permutation, channel model ----------------
// src_X[q] = the PCS lane that arrives on physical lane q; skw_X[q] its delay in blocks
int src_ab [4] = '{0, 1, 2, 3}, skw_ab [4] = '{0, 0, 0, 0};
int src_ba [4] = '{0, 1, 2, 3}, skw_ba [4] = '{0, 0, 0, 0};
logic [65:0] dl_ab [4][256], dl_ba [4][256];
int wp_ab = 0, wp_ba = 0;
logic [1:0]  ch_ab_h [4], ch_ba_h [4];
logic [63:0] ch_ab_d [4], ch_ba_d [4];

always @(posedge clk_a) begin
    wp_ab = (wp_ab + 1) % 256;
    for (int l = 0; l < 4; l++) dl_ab[l][wp_ab] = {a_tx_data[64*l +: 64], a_tx_hdr[2*l +: 2]};
    for (int q = 0; q < 4; q++) {ch_ab_d[q], ch_ab_h[q]} = dl_ab[src_ab[q]][(wp_ab - skw_ab[q] + 256) % 256];
end
always @(posedge clk_b) begin
    wp_ba = (wp_ba + 1) % 256;
    for (int l = 0; l < 4; l++) dl_ba[l][wp_ba] = {b_tx_data[64*l +: 64], b_tx_hdr[2*l +: 2]};
    for (int q = 0; q < 4; q++) {ch_ba_d[q], ch_ba_h[q]} = dl_ba[src_ba[q]][(wp_ba - skw_ba[q] + 256) % 256];
end

for (genvar q = 0; q < 4; q++) begin : g_ch
    tb_gt_chan ch_ab (.clk(rck_b[q]), .tx_hdr(ch_ab_h[q]), .tx_data(ch_ab_d[q]), .rx_slip(b_slip[q]),
                      .rx_hdr(b_rx_hdr[2*q +: 2]), .rx_data(b_rx_data[64*q +: 64]), .rx_valid(b_rx_valid[q]));
    tb_gt_chan ch_ba (.clk(rck_a[q]), .tx_hdr(ch_ba_h[q]), .tx_data(ch_ba_d[q]), .rx_slip(a_slip[q]),
                      .rx_hdr(a_rx_hdr[2*q +: 2]), .rx_data(a_rx_data[64*q +: 64]), .rx_valid(a_rx_valid[q]));
end

// the 24 permutations of 4 lanes, in lexicographic order
function automatic void perm_of(int k, ref int src [4]);
    int pool [$];
    int f;
    pool = '{0, 1, 2, 3};
    for (int i = 0; i < 4; i++) begin
        f = (i == 0) ? 6 : (i == 1) ? 2 : (i == 2) ? 1 : 1;
        src[i] = pool[k / f];
        pool.delete(k / f);
        k = k % f;
    end
endfunction

// ---------------- event counters ----------------
int cnt_a [15], cnt_b [15], bip_a [4], bip_b [4];
bit count_en = 1'b0;
int a_wd_n = 0, b_wd_n = 0;
logic a_wd_d = 1'b0, b_wd_d = 1'b0;
always @(posedge clk_a) begin
    if (count_en) begin
        for (int i = 0; i < 15; i++) if (a_ev[i]) cnt_a[i]++;
        for (int i = 0; i < 4; i++) if (a_bip[i]) bip_a[i]++;
    end
    if (a_wd && !a_wd_d) a_wd_n++;
    a_wd_d <= a_wd;
end
always @(posedge clk_b) begin
    if (count_en) begin
        for (int i = 0; i < 15; i++) if (b_ev[i]) cnt_b[i]++;
        for (int i = 0; i < 4; i++) if (b_bip[i]) bip_b[i]++;
    end
    if (b_wd && !b_wd_d) b_wd_n++;
    b_wd_d <= b_wd;
end

task automatic print_counts();
    $display("TB_CNT_A txf=%0d txp=%0d und=%0d abt=%0d good=%0d bad=%0d fcs=%0d runt=%0d over=%0d rxp=%0d badblk=%0d seq=%0d ovf=%0d skf=%0d bip=%0d",
             cnt_a[0], cnt_a[1], cnt_a[2], cnt_a[3], cnt_a[4], cnt_a[5], cnt_a[6], cnt_a[7], cnt_a[8], cnt_a[9],
             cnt_a[10], cnt_a[11], cnt_a[12], cnt_a[13], bip_a[0] + bip_a[1] + bip_a[2] + bip_a[3]);
    $display("TB_CNT_B txf=%0d txp=%0d und=%0d abt=%0d good=%0d bad=%0d fcs=%0d runt=%0d over=%0d rxp=%0d badblk=%0d seq=%0d ovf=%0d skf=%0d bip=%0d",
             cnt_b[0], cnt_b[1], cnt_b[2], cnt_b[3], cnt_b[4], cnt_b[5], cnt_b[6], cnt_b[7], cnt_b[8], cnt_b[9],
             cnt_b[10], cnt_b[11], cnt_b[12], cnt_b[13], bip_b[0] + bip_b[1] + bip_b[2] + bip_b[3]);
endtask

// ---------------- TX drivers ----------------
typedef struct { int gap; int abort_beat; int under_beat; byte unsigned b[$]; } tframe_t;
tframe_t txq_a [$], txq_b [$];
bit tx_go = 1'b0;
bit tx_cont_b = 1'b0;          // B sends filler frames continuously (pause test)
int tx_done_a = 0, tx_done_b = 0;
int tx_hold_a = 0;             // A's driver waits while > 0 (perms test: one batch at a time)

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

`define TX_DRIVER(X, CLK, CONT, HOLD) \
initial begin : drv_``X \
    tframe_t f; int nb, i; \
    X``_s_tvalid = 1'b0; \
    wait (tx_go); \
    while (txq_``X.size() > 0 || CONT) begin \
        while (HOLD > 0) @(posedge CLK); \
        if (txq_``X.size() > 0) f = txq_``X.pop_front(); \
        else begin f.gap = 3; f.abort_beat = -1; f.under_beat = -1; f.b.delete(); \
                   for (int k = 0; k < 200; k++) f.b.push_back(8'(k)); end \
        repeat (f.gap) @(posedge CLK); \
        nb = (f.b.size() + 31) / 32; \
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
            for (int k = 0; k < 32; k++) begin \
                i = bt * 32 + k; \
                if (i < f.b.size()) begin X``_s_tdata[8*k +: 8] <= f.b[i]; X``_s_tkeep[k] <= 1'b1; end \
            end \
            do @(posedge CLK); while (!X``_s_tready); \
        end \
        X``_s_tvalid <= 1'b0; \
        X``_s_tuser  <= 1'b0; \
        tx_done_``X++; \
    end \
end

int zero = 0;
`TX_DRIVER(a, clk_a, 1'b0, tx_hold_a)
`TX_DRIVER(b, clk_b, tx_cont_b, zero)

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
            for (int k = 0; k < 32; k++) begin \
                if (X``_m_tkeep[k]) begin \
                    if (seen_last) keep_err++; \
                    q.push_back(X``_m_tdata[8*k +: 8]); nk++; \
                end else seen_last = 1'b1; \
            end \
            if (nk == 0 || (!X``_m_tlast && nk != 32)) keep_err++; \
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

// ---------------- capture of the A -> B lanes as B's physical lanes see them ----------------
integer fcap = 0;
int     capn = 0, capd = 0;
bit     cap_en = 1'b0;
always @(posedge clk_a) begin
    if (cap_en && fcap != 0 && capd < capn) begin
        $fdisplay(fcap, "%0d %016x %0d %016x %0d %016x %0d %016x", ch_ab_h[0], ch_ab_d[0], ch_ab_h[1], ch_ab_d[1],
                  ch_ab_h[2], ch_ab_d[2], ch_ab_h[3], ch_ab_d[3]);
        capd++;
    end
end

// ---------------- helpers ----------------
task automatic wait_link(output int cyc_a, output int cyc_b, input int lim = 600000);
    int n;
    n = 0; cyc_a = -1; cyc_b = -1;
    while ((cyc_a < 0 || cyc_b < 0) && n < lim) begin
        @(posedge clk_a);
        n++;
        if (cyc_a < 0 && a_link) cyc_a = n;
        if (cyc_b < 0 && b_link) cyc_b = n;
    end
endtask

task automatic wait_b(input bit lvl, output int cyc, input int lim);
    cyc = -1;
    for (int n = 1; n <= lim && cyc < 0; n++) begin
        @(posedge clk_b);
        if (b_link == lvl) cyc = n;
    end
endtask

// B's link up and staying up for `hold` cycles (after an abrupt change in the TB the
// lanes may align on the old marker positions once before AM lock catches up)
task automatic wait_b_stable(output int cyc, input int lim, input int hold);
    int n, run;
    cyc = -1; run = 0;
    for (n = 1; n <= lim && cyc < 0; n++) begin
        @(posedge clk_b);
        run = b_link ? run + 1 : 0;
        if (run == hold) cyc = n - hold + 1;
    end
endtask

// high periods of B's stat_rx_pause_req (clk_b cycles) and B's frame starts while it was high
int pz_len [$];
int pz_cur = 0;
int starts_in_pause = 0, starts_total = 0;
always @(posedge clk_b) begin
    if (b_preq) pz_cur++;
    else if (pz_cur != 0) begin
        pz_len.push_back(pz_cur);
        pz_cur = 0;
    end
    if (dut_b.u_mac_tx.a_start) begin
        starts_total++;
        if (pz_cur > 8) starts_in_pause++;
    end
end

// A's transmitted frames over time (rate test): cycle of every ev_tx_frame
int   a_cyc = 0;
int   txf_t [$];
always @(posedge clk_a) begin
    a_cyc++;
    if (count_en && a_ev[0]) txf_t.push_back(a_cyc);
end

// ---------------- main ----------------
initial begin
    string mode, fa, fb, oa, ob, cap, sks;
    int la, lb, n, t_set, t_clr, ok, pk, nper, cyc, rx0;
    int sk [4];
    if (!$value$plusargs("mode=%s", mode)) mode = "frames";
    if ($value$plusargs("fa=%s", fa)) load_frames(fa, txq_a);
    if ($value$plusargs("fb=%s", fb)) load_frames(fb, txq_b);
    if ($value$plusargs("oa=%s", oa)) fo_a = $fopen(oa, "w");
    if ($value$plusargs("ob=%s", ob)) fo_b = $fopen(ob, "w");
    if ($value$plusargs("cap=%s", cap)) fcap = $fopen(cap, "w");
    if (!$value$plusargs("capn=%d", capn)) capn = 0;
    if (!$value$plusargs("nper=%d", nper)) nper = 25;
    if ($value$plusargs("perm=%d", pk)) perm_of(pk, src_ab);
    if ($value$plusargs("skew=%s", sks)) begin
        void'($sscanf(sks, "%d,%d,%d,%d", sk[0], sk[1], sk[2], sk[3]));
        for (int q = 0; q < 4; q++) skw_ab[q] = sk[q];
    end
    // B -> A: a fixed scramble of the lanes and some skew
    perm_of(17, src_ba);
    skw_ba = '{3, 0, 11, 6};
    $display("TB_INFO mode=%s frames_a=%0d frames_b=%0d src_ab=%0d%0d%0d%0d skew_ab=%0d,%0d,%0d,%0d am_period=%0d",
             mode, txq_a.size(), txq_b.size(), src_ab[0], src_ab[1], src_ab[2], src_ab[3],
             skw_ab[0], skw_ab[1], skw_ab[2], skw_ab[3], AM_PERIOD);

    repeat (10) @(posedge clk_a);
    rst_a <= 1'b0;
    rst_b <= 1'b0;
    repeat (20) @(posedge clk_a);
    gt_ready <= 1'b1;

    if (mode == "watchdog") begin
        begin g_ch[0].ch_ab.kill = 1'b1; g_ch[1].ch_ab.kill = 1'b1; g_ch[2].ch_ab.kill = 1'b1; g_ch[3].ch_ab.kill = 1'b1; end
        repeat (WD * 3 + 1000) @(posedge clk_b);
        $display("TB_WD b_pulses=%0d a_pulses=%0d b_lock=%0d a_lock=%0d", b_wd_n, a_wd_n, b_lock, a_lock);
        $display("TB_DONE");
        $finish;
    end

    wait_link(la, lb);
    $display("TB_LINK a=%0d b=%0d b_map=0x%02x a_map=0x%02x b_skew=%0d a_skew=%0d", la, lb, b_lmap, a_lmap, b_lskew, a_lskew);
    if (la < 0 || lb < 0) begin
        $display("TB_FAIL no link llock_b=%b laml_b=%b llock_a=%b laml_a=%b", b_llock, b_laml, a_llock, a_laml);
        $display("TB_DONE");
        $finish;
    end
    repeat (50) @(posedge clk_a);
    count_en = 1'b1;
    cap_en   = 1'b1;

    if (mode == "frames" || mode == "errors" || mode == "rate") begin
        if (mode == "errors") g_ch[2].ch_ba.dflip = 400;
        tx_go = 1'b1;
        n = 0;
        while ((txq_a.size() > 0 || txq_b.size() > 0 || a_s_tvalid || b_s_tvalid) && n < 8000000) begin
            @(posedge clk_a); n++;
        end
        repeat (3000) @(posedge clk_a);
        // the capture must hold a few marker periods for the Python decoder
        while (fcap != 0 && capd < capn && capd < 3 * AM_PERIOD + 2000) @(posedge clk_a);
        $display("TB_INJ dflip_ba=%0d", g_ch[2].ch_ba.n_dflip);
        if (mode == "rate") begin
            int n_min;
            if (!$value$plusargs("nmin=%d", n_min)) n_min = 0;
            if (txf_t.size() > n_min) begin
                $display("TB_RATE grp=min n=%0d cycles=%0d", n_min, txf_t[n_min - 1] - txf_t[0]);
                $display("TB_RATE grp=max n=%0d cycles=%0d", txf_t.size() - n_min, txf_t[txf_t.size() - 1] - txf_t[n_min]);
            end
        end
    end else if (mode == "overflow") begin
        // B's user side stops reading for a while (forced), A keeps sending
        tx_go = 1'b1;
        repeat (3000) @(posedge clk_b);
        // (the banks look empty to their read side: read pointer = write pointer)
        force dut_b.u_bank0.rd_wptr = dut_b.u_bank0.rd_ptr;
        force dut_b.u_bank1.rd_wptr = dut_b.u_bank1.rd_ptr;
        repeat (4000) @(posedge clk_b);
        release dut_b.u_bank0.rd_wptr;
        release dut_b.u_bank1.rd_wptr;
        n = 0;
        while ((txq_a.size() > 0 || a_s_tvalid) && n < 8000000) begin
            @(posedge clk_a); n++;
        end
        repeat (3000) @(posedge clk_a);
    end else if (mode == "perms") begin
        // every permutation (random order) with random skew: relock, then a batch of frames
        int order [24];
        int dn, up, sent;
        for (int i = 0; i < 24; i++) order[i] = i;
        order.shuffle();
        tx_hold_a = 1;
        tx_go = 1'b1;
        sent = 0;
        for (int i = 0; i < 24; i++) begin
            perm_of(order[i], src_ab);
            for (int q = 0; q < 4; q++) skw_ab[q] = $urandom_range(DESKEW_MAX - 3);
            wait_b(1'b0, dn, 20 * AM_PERIOD);
            wait_b_stable(up, 60 * AM_PERIOD, 6 * AM_PERIOD);
            repeat (100) @(posedge clk_b);
            $display("TB_PERM i=%0d perm=%0d src=%0d%0d%0d%0d skew=%0d,%0d,%0d,%0d down=%0d up=%0d map=0x%02x measured=%0d",
                     i, order[i], src_ab[0], src_ab[1], src_ab[2], src_ab[3], skw_ab[0], skw_ab[1], skw_ab[2], skw_ab[3],
                     dn, up, b_lmap, b_lskew);
            rx0 = rx_n_b;
            tx_hold_a = 0;
            while (tx_done_a < sent + nper) @(posedge clk_a);
            tx_hold_a = 1;
            sent += nper;
            n = 0;
            while (rx_n_b < rx0 + nper && n < 400000) begin @(posedge clk_b); n++; end
            repeat (200) @(posedge clk_b);
        end
    end else if (mode == "skew") begin
        // skew beyond DESKEW_MAX on one lane: no alignment; back within the limit: relock
        skw_ab[1] = DESKEW_MAX + 6;
        wait_b(1'b0, t_set, 20 * AM_PERIOD);
        n = cnt_b[13];
        ok = 1;
        for (int i = 0; i < 12 * AM_PERIOD; i++) begin @(posedge clk_b); if (b_link || b_lock) ok = 0; end
        $display("TB_SKEW1 down_after=%0d no_align=%0d skew_fails=%0d lf=%0d a_rf=%0d", t_set, ok, cnt_b[13] - n, b_lf, a_rf);
        skw_ab[1] = DESKEW_MAX - 4;
        wait_b_stable(t_clr, 40 * AM_PERIOD, 6 * AM_PERIOD);
        repeat (10) @(posedge clk_b);
        $display("TB_SKEW2 up_after=%0d measured=%0d", t_clr, b_lskew);
        tx_go = 1'b1;
        n = 0;
        while ((txq_a.size() > 0 || a_s_tvalid) && n < 4000000) begin @(posedge clk_a); n++; end
        repeat (3000) @(posedge clk_a);
    end else if (mode == "lanefail") begin
        // 1: physical lane 2 of A -> B dies: B loses alignment (local fault), A sees remote fault
        g_ch[2].ch_ab.kill = 1'b1;
        wait_b(1'b0, t_set, 200000);
        repeat (3000) @(posedge clk_a);
        $display("TB_LANE1 down_after=%0d b_llock=%b b_lock=%0d b_lf=%0d a_rf=%0d a_link=%0d b_out_rf=%0d",
                 t_set, b_llock, b_lock, b_lf, a_rf, a_link,
                 dut_b.t_xc == {4{8'hF1}} && dut_b.t_xd[63:0] == {32'h07070707, 8'h02, 16'h0, 8'h9C});
        g_ch[2].ch_ab.kill = 1'b0;
        wait_link(la, lb, 40 * AM_PERIOD + 100000);
        $display("TB_LANE1R a=%0d b=%0d", la, lb);
    end else if (mode == "hiber") begin
        // 1: low error rate on one lane, no hi_ber
        g_ch[1].ch_ab.hdr_rate = 8000;
        ok = 1;
        for (int i = 0; i < 2 * BER_TIMER; i++) begin @(posedge clk_b); if (b_hiber) ok = 0; end
        $display("TB_HIBER1 hdr_errs=%0d no_hiber=%0d lock=%0d", g_ch[1].ch_ab.n_hdr, ok, b_lock);
        // 2: high rate, hi_ber within a window
        g_ch[1].ch_ab.hdr_rate = 150;
        t_set = -1;
        for (int i = 0; i < 2 * BER_TIMER && t_set < 0; i++) begin @(posedge clk_b); if (b_hiber) t_set = i; end
        repeat (100) @(posedge clk_b);
        $display("TB_HIBER2 set_after=%0d b_link=%0d b_lf=%0d a_rf=%0d lock=%0d", t_set, b_link, b_lf, a_rf, b_lock);
        // 3: errors off, hi_ber clears
        g_ch[1].ch_ab.hdr_rate = 0;
        t_clr = -1;
        for (int i = 0; i < 3 * BER_TIMER && t_clr < 0; i++) begin @(posedge clk_b); if (!b_hiber) t_clr = i; end
        wait_link(la, lb);
        $display("TB_HIBER3 clr_after=%0d link_a=%0d link_b=%0d", t_clr, la, lb);
    end else if (mode == "pause") begin
        b_honour  = 1'b1;
        tx_cont_b = 1'b1;
        tx_go     = 1'b1;
        repeat (500) @(posedge clk_a);
        // 1: XOFF 100 quanta (200 cycles at 256 bit times per cycle), held longer than that
        a_pq = 16'd100; a_pref = 16'd0;
        a_psend = 1'b1; repeat (1500) @(posedge clk_a); a_psend = 1'b0;
        repeat (1000) @(posedge clk_a);
        // 2: XOFF 65535 quanta, XON after 2000 cycles
        a_pq = 16'd65535;
        a_psend = 1'b1; repeat (2000) @(posedge clk_a); a_psend = 1'b0;
        repeat (1000) @(posedge clk_a);
        // 3: XOFF 200 quanta refreshed every 100 quanta for 10000 cycles, then XON
        a_pq = 16'd200; a_pref = 16'd100;
        a_psend = 1'b1; repeat (10000) @(posedge clk_a); a_psend = 1'b0;
        repeat (1000) @(posedge clk_a);
        tx_cont_b = 1'b0;
        repeat (2000) @(posedge clk_a);
        foreach (pz_len[i]) $display("TB_PAUSE i=%0d cycles=%0d", i, pz_len[i]);
        $display("TB_PSTARTS total=%0d in_pause=%0d", starts_total, starts_in_pause);
    end else if (mode == "fault") begin
        b_tx_fault = 1'b1;
        repeat (2000) @(posedge clk_a);
        repeat (1000) @(posedge clk_a);
        $display("TB_FAULT1 a_lf=%0d a_rf=%0d a_link=%0d b_lf=%0d b_rf=%0d b_link=%0d a_out_rf=%0d",
                 a_lf, a_rf, a_link, b_lf, b_rf, b_link,
                 dut_a.t_xc == {4{8'hF1}} && dut_a.t_xd == {4{32'h07070707, 8'h02, 16'h0, 8'h9C}});
        b_tx_fault = 1'b0;
        wait_link(la, lb);
        $display("TB_FAULT1R a=%0d b=%0d", la, lb);
        tx_cont_b = 1'b1;
        tx_go = 1'b1;
        begin g_ch[0].ch_ba.kill = 1'b1; g_ch[1].ch_ba.kill = 1'b1; g_ch[2].ch_ba.kill = 1'b1; g_ch[3].ch_ba.kill = 1'b1; end
        repeat (3000) @(posedge clk_a);
        ok = 1;
        for (int i = 0; i < 500; i++) begin
            @(posedge clk_b);
            if (!(dut_b.t_xc == '1 && dut_b.t_xd == {32{8'h07}})) ok = 0;
        end
        $display("TB_FAULT2 a_lock=%0d a_lf=%0d b_rf=%0d b_link=%0d b_idles=%0d b_tready=%0d",
                 a_lock, a_lf, b_rf, b_link, ok, b_s_tready);
        begin g_ch[0].ch_ba.kill = 1'b0; g_ch[1].ch_ba.kill = 1'b0; g_ch[2].ch_ba.kill = 1'b0; g_ch[3].ch_ba.kill = 1'b0; end
        tx_cont_b = 1'b0;
        wait_link(la, lb);
        $display("TB_FAULT2R a=%0d b=%0d", la, lb);
    end
    print_counts();
    $display("TB_RX a=%0d b=%0d keep_err=%0d ctrl_seen=%0d tx_done_a=%0d tx_done_b=%0d",
             rx_n_a, rx_n_b, keep_err, ctrl_seen, tx_done_a, tx_done_b);
    $display("TB_SLIPS ab=%0d,%0d,%0d,%0d ba=%0d,%0d,%0d,%0d", g_ch[0].ch_ab.n_slip, g_ch[1].ch_ab.n_slip,
             g_ch[2].ch_ab.n_slip, g_ch[3].ch_ab.n_slip, g_ch[0].ch_ba.n_slip, g_ch[1].ch_ba.n_slip,
             g_ch[2].ch_ba.n_slip, g_ch[3].ch_ba.n_slip);
    if (fo_a) $fclose(fo_a);
    if (fo_b) $fclose(fo_b);
    if (fcap) $fclose(fcap);
    $display("TB_DONE");
    $finish;
end

endmodule
