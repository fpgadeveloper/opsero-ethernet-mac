// SPDX-License-Identifier: MIT
//
// tb_omac_10g_usx - one omac_10g with USXGMII_EN = 1 (and TS_EN = 1) against the
// behavioural USXGMII PHY model tb_usx_phy. PHY -> DUT through the bit-level
// channel model tb_gt_chan (random block phase, gearbox slip, error bursts);
// DUT -> PHY block-aligned. The PHY runs on a clock 100 ppm slower than the
// DUT's (the DUT receives on it, as on a recovered clock).
// A test is a list of phases; in each phase the PHY takes a new word (speed,
// link, duplex) and restarts auto-negotiation (or both sides are forced to the
// speed), the testbench waits for the link at the new speed, then frames go
// both ways and are drained.
// Plusargs:
//   +speeds=<c,c,...>     speed code per phase (word bits 11:9: 0 10M, 1 100M,
//                         2 1G, 3 10G, 4 2.5G, 5 5G)
//   +an=<0|1>             1: auto-negotiation; 0: DUT forced (ctl_usx_an_enable
//                         = 0, ctl_usx_speed) and PHY forced
//   +fa<p>=<file> +fb<p>=<file>  frames the DUT / the PHY sends in phase p
//                         (DUT: "len gap abort_beat under_beat hex"; PHY: the
//                         same format, abort_beat >= 0 = a wrong FCS)
//   +oa=<file>            frames received by the DUT ("user hex"), all phases
//   +ra=<file> +ta=<file> DUT receive / transmit timestamps
//   +pr=<file> +ps=<file> frames received by the PHY ("ok cyc lane hex"), the
//                         PHY's sent /S/ blocks ("cyc lane corrupt")
//   +stress=<p,...> +lpi=<p,...> +corrupt=<p,...> +strict=<p,...> +txfmt=<p,...>
//   +resignal=<p,...>     per-phase knobs (percent / 0-1), default 0
//   +lockloss=<p>         after phase p: a burst of invalid headers to the DUT
//   +lt=<n>               the DUT's link timer through ctl_usx_link_timer (0 = parameter)
// Results: TB_PH (link per phase), TB_PE (phase end: counts), TB_DONE.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1fs
`default_nettype none

module tb_omac_10g_usx #(
    parameter int LT = 2000          // link timers (DUT parameter and PHY model), clk cycles
);

`include "tb_util.svh"

localparam realtime PA = 6.4;
localparam realtime PB = PA * 1.0001;
logic clk = 1'b0, pclk = 1'b0;
always #(PA / 2) clk = ~clk;
always #(PB / 2) pclk = ~pclk;

logic rst = 1'b1, gt_ready = 1'b0;
logic [31:0] cyc = '0, pcyc = '0;
always @(posedge clk) cyc <= cyc + 1;
always @(posedge pclk) pcyc <= pcyc + 1;

logic [63:0] s_tdata;
logic [7:0]  s_tkeep;
logic        s_tvalid = 1'b0, s_tlast = 1'b0;
logic [0:0]  s_tuser = '0;
wire         s_tready;
wire  [63:0] m_tdata;
wire  [7:0]  m_tkeep;
wire         m_tvalid, m_tlast;
wire  [0:0]  m_tuser;
wire  [1:0]  tx_hdr, rx_hdr, p_hdr;
wire  [63:0] tx_data, rx_data, p_data;
wire         rx_valid, slip;
wire         link, lock;
wire  [11:0] ev;
wire         ts_v, ts_l4, ts_u, rts_l4;
wire  [31:0] ts_val, rts;
logic        an_en = 1'b1, an_restart = 1'b0, strict = 1'b0;
logic [2:0]  fspeed = 3'd3;
logic [19:0] lt_ctl = '0;
wire         an_cpl, usx_ok, ev_an_s, ev_an_d, ev_rep;
wire  [2:0]  an_st, usx_speed;
wire  [15:0] lp_word;

omac_10g #(.TS_EN(1), .TS_W(32), .USXGMII_EN(1), .USX_LINK_TIMER(LT), .MAX_FRAME(9600)) dut (
    .clk(clk), .rst(rst),
    .s_axis_tx_tdata(s_tdata), .s_axis_tx_tkeep(s_tkeep), .s_axis_tx_tvalid(s_tvalid),
    .s_axis_tx_tready(s_tready), .s_axis_tx_tlast(s_tlast), .s_axis_tx_tuser(s_tuser),
    .m_axis_rx_tdata(m_tdata), .m_axis_rx_tkeep(m_tkeep), .m_axis_rx_tvalid(m_tvalid),
    .m_axis_rx_tlast(m_tlast), .m_axis_rx_tuser(m_tuser),
    .ctl_tx_enable(1'b1), .ctl_rx_enable(1'b1), .ctl_loopback(1'b0), .ctl_tx_fault(1'b0),
    .ctl_pause_tx_honour(1'b0), .ctl_tx_pause_send(1'b0), .ctl_tx_pause_quanta(16'd0),
    .ctl_tx_pause_refresh(16'd0), .ctl_mac_addr(48'h01_EF_CD_AB_00_02),
    .stat_link_up(link), .stat_block_lock(lock), .stat_hi_ber(), .stat_local_fault(), .stat_remote_fault(),
    .stat_rx_pause_req(), .stat_rx_pause_quanta(), .stat_tx_pause_active(),
    .ev_tx_frame(ev[0]), .ev_tx_pause(ev[1]), .ev_tx_underflow(ev[2]), .ev_tx_abort(ev[3]),
    .ev_rx_frame_good(ev[4]), .ev_rx_frame_bad(ev[5]), .ev_rx_fcs_error(ev[6]),
    .ev_rx_runt(ev[7]), .ev_rx_oversize(ev[8]), .ev_rx_pause(ev[9]),
    .ev_rx_bad_block(ev[10]), .ev_rx_sequence_error(ev[11]),
    .gt_tx_ready(gt_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data), .gt_loopback(),
    .gt_rx_clk(pclk), .gt_rx_ready(gt_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
    .gt_rx_data(rx_data), .gt_rx_slip(slip), .gt_rx_reset_req(),
    .tx_ts_in(cyc), .tx_ts_valid(ts_v), .tx_ts_val(ts_val), .tx_ts_lane4(ts_l4), .tx_ts_user(ts_u),
    .rx_ts_in(pcyc), .m_axis_rx_ts(rts), .m_axis_rx_ts_lane4(rts_l4),
    .ctl_usx_an_enable(an_en), .ctl_usx_an_restart(an_restart), .ctl_usx_an_adv(16'h9601),
    .ctl_usx_speed(fspeed), .ctl_usx_link_timer(lt_ctl), .ctl_usx_rx_strict(strict),
    .stat_usx_an_complete(an_cpl), .stat_usx_an_state(an_st), .stat_usx_lp_word(lp_word),
    .stat_usx_speed(usx_speed), .stat_usx_link_ok(usx_ok),
    .ev_usx_an_start(ev_an_s), .ev_usx_an_done(ev_an_d), .ev_usx_rep_error(ev_rep));

tb_usx_phy #(.LINK_TIMER(LT)) phy (
    .tx_clk(pclk), .tx_hdr(p_hdr), .tx_data(p_data),
    .rx_clk(clk), .rx_hdr(tx_hdr), .rx_data(tx_data), .tx_cyc(pcyc), .rx_cyc(cyc));

tb_gt_chan ch (.clk(pclk), .tx_hdr(p_hdr), .tx_data(p_data), .rx_slip(slip),
               .rx_hdr(rx_hdr), .rx_data(rx_data), .rx_valid(rx_valid));

// ---------------- event counters ----------------
int cnt [12];
int n_rep = 0, n_an_s = 0, n_an_d = 0;
always @(posedge clk) begin
    for (int i = 0; i < 12; i++) if (ev[i]) cnt[i]++;
    if (ev_rep) n_rep++;
    if (ev_an_s) n_an_s++;
    if (ev_an_d) n_an_d++;
end

// ---------------- DUT transmit driver ----------------
typedef struct { int gap; int abort_beat; int under_beat; byte unsigned b[$]; } tframe_t;
tframe_t txq [$];
int tx_done = 0;

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

initial begin : drv
    tframe_t f; int nb, i;
    forever begin
        wait (txq.size() > 0);
        f = txq.pop_front();
        repeat (f.gap) @(posedge clk);
        nb = (f.b.size() + 7) / 8;
        for (int bt = 0; bt < nb; bt++) begin
            if (bt == f.under_beat) begin
                s_tvalid <= 1'b0;
                // a missing beat: tvalid low for three enabled cycles of the MAC
                repeat (3 * phy.rep) @(posedge clk);
            end
            s_tvalid <= 1'b1;
            s_tlast  <= (bt == nb - 1);
            s_tuser  <= (bt == f.abort_beat);
            s_tdata  <= 'x;
            s_tkeep  <= '0;
            for (int k = 0; k < 8; k++) begin
                i = bt * 8 + k;
                if (i < f.b.size()) begin s_tdata[8*k +: 8] <= f.b[i]; s_tkeep[k] <= 1'b1; end
            end
            do @(posedge clk); while (!s_tready);
        end
        s_tvalid <= 1'b0;
        s_tuser  <= 1'b0;
        tx_done++;
    end
end

// ---------------- DUT receive monitor, timestamps ----------------
int rx_n = 0, keep_err = 0, tsc_err = 0;
integer fo = 0, fr = 0, ft = 0;
initial begin : mon
    byte unsigned q[$]; int nk; bit seen_last;
    logic [31:0] ts0; logic l40; bit tsc;
    forever begin
        @(posedge clk);
        if (m_tvalid) begin
            if (q.size() == 0) begin ts0 = rts; l40 = rts_l4; tsc = 1'b1; end
            else if (rts !== ts0 || rts_l4 !== l40) tsc = 1'b0;
            nk = 0; seen_last = 1'b0;
            for (int k = 0; k < 8; k++) begin
                if (m_tkeep[k]) begin
                    if (seen_last) keep_err++;
                    q.push_back(m_tdata[8*k +: 8]); nk++;
                end else seen_last = 1'b1;
            end
            if (nk == 0 || (!m_tlast && nk != 8)) keep_err++;
            if (m_tlast) begin
                if (fo != 0) $fdisplay(fo, "%0d %s", m_tuser, tb_bytes2hex(q));
                if (fr != 0) $fdisplay(fr, "%0d %0d %0d", ts0, l40, tsc);
                if (!tsc) tsc_err++;
                rx_n++;
                q.delete();
            end
        end
    end
end
int tx_ts_n = 0;
always @(posedge clk) if (ts_v) begin
    tx_ts_n++;
    if (ft != 0) $fdisplay(ft, "%0d %0d %0d", ts_val, ts_l4, ts_u);
end

// ---------------- helpers ----------------
function automatic int csv_get(string s, int idx, int dflt);
    int v, n, i0;
    string t;
    n = 0; i0 = 0;
    for (int i = 0; i <= s.len(); i++) begin
        if (i == s.len() || s[i] == ",") begin
            if (n == idx) begin
                t = s.substr(i0, i - 1);
                v = t.atoi();
                return v;
            end
            n++;
            i0 = i + 1;
        end
    end
    return dflt;
endfunction

function automatic int csv_len(string s);
    int n;
    if (s.len() == 0) return 0;
    n = 1;
    for (int i = 0; i < s.len(); i++) if (s[i] == ",") n++;
    return n;
endfunction

task automatic wait_cycles(int n);
    repeat (n) @(posedge clk);
endtask

// ---------------- main ----------------
initial begin
    string sp, s_stress, s_lpi, s_cor, s_strict, s_fmt, s_resig, fn;
    int nph, an, lockloss, code, t, n_exp_dut, n_exp_phy, rx0, prx0, lt_arg;
    int c_rep0, c_good0, c_bad0, c_fcs0, viol0, fill0, align0, gap0, slane0, dec0;
    tframe_t pf [$];
    if (!$value$plusargs("speeds=%s", sp)) sp = "3";
    if (!$value$plusargs("an=%d", an)) an = 1;
    if (!$value$plusargs("stress=%s", s_stress)) s_stress = "";
    if (!$value$plusargs("lpi=%s", s_lpi)) s_lpi = "";
    if (!$value$plusargs("corrupt=%s", s_cor)) s_cor = "";
    if (!$value$plusargs("strict=%s", s_strict)) s_strict = "";
    if (!$value$plusargs("txfmt=%s", s_fmt)) s_fmt = "";
    if (!$value$plusargs("resignal=%s", s_resig)) s_resig = "";
    if (!$value$plusargs("lockloss=%d", lockloss)) lockloss = -1;
    if (!$value$plusargs("lt=%d", lt_arg)) lt_arg = 0;
    if ($value$plusargs("oa=%s", fn)) fo = $fopen(fn, "w");
    if ($value$plusargs("ra=%s", fn)) fr = $fopen(fn, "w");
    if ($value$plusargs("ta=%s", fn)) ft = $fopen(fn, "w");
    nph = csv_len(sp);
    lt_ctl = 20'(lt_arg);
    an_en = (an != 0);
    phy.an_en = (an != 0);
    phy.go = 1'b0;
    code = csv_get(sp, 0, 3);
    phy.word = 16'h9001 | (16'(code) << 9);
    phy.force_rep = phy.rep_of(3'(code));
    fspeed = 3'(code);
    $display("TB_INFO phases=%0d speeds=%s an=%0d phase=%0d lt=%0d", nph, sp, an, ch.phase, LT);

    repeat (10) @(posedge clk);
    rst <= 1'b0;
    repeat (20) @(posedge clk);
    gt_ready <= 1'b1;

    for (int p = 0; p < nph; p++) begin
        code = csv_get(sp, p, 3);
        phy.stress   = csv_get(s_stress, p, 0);
        phy.lpi      = csv_get(s_lpi, p, 0);
        phy.corrupt  = csv_get(s_cor, p, 0);
        phy.txfmt    = csv_get(s_fmt, p, 0);
        phy.resignal = csv_get(s_resig, p, 0);
        strict       = csv_get(s_strict, p, 0);
        phy.go = 1'b0;
        if (p > 0) begin
            if (an) begin
                phy.word = 16'h9001 | (16'(code) << 9);
                phy.restart_req = 1'b1;
            end else begin
                fspeed = 3'(code);
                phy.force_rep = phy.rep_of(3'(code));
            end
        end
        // link at the new speed: both ends at link, the DUT's speed = the PHY's
        t = 0;
        do begin @(posedge clk); t++; end
        while (!(link && phy.link && usx_speed == 3'(code) && (an == 0 || (an_cpl && phy.st == 6))) && t < 3000000);
        repeat (200) @(posedge clk);
        $display("TB_PH p=%0d code=%0d link=%0d t=%0d dut_speed=%0d lp_word=0x%04x phy_dut_word=0x%04x phy_rep=%0d an_cpl=%0d an_starts=%0d an_done=%0d phy_an_done=%0d",
                 p, code, link, t, usx_speed, lp_word, phy.dut_word, phy.rep, an_cpl, n_an_s, n_an_d, phy.n_an_done);
        if (!link) begin
            $display("TB_FAIL no link in phase %0d", p);
            break;
        end
        // frames both ways
        c_rep0 = n_rep; c_good0 = cnt[4]; c_bad0 = cnt[5]; c_fcs0 = cnt[6];
        viol0 = phy.n_rep_viol; fill0 = phy.n_fill_err; align0 = phy.n_align_err; gap0 = phy.n_gap_err;
        slane0 = phy.n_s_lane_err; dec0 = phy.n_dec_err;
        rx0 = rx_n; prx0 = phy.rxq.size();
        phy.ipg_min = 1 << 30; phy.ipg_sum = 0; phy.ipg_n = 0;
        n_exp_dut = 0; n_exp_phy = 0;
        if ($value$plusargs($sformatf("fb%0d=%%s", p), fn)) begin
            load_frames(fn, pf);
            n_exp_dut = pf.size();
            foreach (pf[i]) phy.push_tx(pf[i].b, pf[i].abort_beat >= 0);
            pf.delete();
        end
        if ($value$plusargs($sformatf("fa%0d=%%s", p), fn)) begin
            load_frames(fn, txq);
            n_exp_phy = txq.size();
        end
        phy.go = 1'b1;
        t = 0;
        while ((rx_n - rx0 < n_exp_dut || phy.rxq.size() - prx0 < n_exp_phy) && t < 30000000) begin
            @(posedge clk); t++;
        end
        repeat (300) @(posedge clk);
        $display("TB_PE p=%0d rx=%0d exp_rx=%0d phy_rx=%0d exp_phy_rx=%0d t=%0d rep_err=%0d good=%0d bad=%0d fcs=%0d phy_viol=%0d phy_fill=%0d phy_align=%0d phy_gap=%0d phy_slane=%0d phy_dec=%0d ipg_min=%0d ipg_sum=%0d ipg_n=%0d phy_corrupt=%0d phy_ins=%0d phy_del=%0d phy_lpi=%0d phy_enc=%0d",
                 p, rx_n - rx0, n_exp_dut, phy.rxq.size() - prx0, n_exp_phy, t, n_rep - c_rep0, cnt[4] - c_good0,
                 cnt[5] - c_bad0, cnt[6] - c_fcs0, phy.n_rep_viol - viol0, phy.n_fill_err - fill0,
                 phy.n_align_err - align0, phy.n_gap_err - gap0, phy.n_s_lane_err - slane0, phy.n_dec_err - dec0,
                 phy.ipg_min, phy.ipg_sum, phy.ipg_n, phy.n_corrupt, phy.n_ins, phy.n_del, phy.n_lpi, phy.n_enc_err);
        if (p == lockloss) begin
            int tl, tr;
            phy.go = 1'b0;
            ch.burst = 200;
            tl = -1;
            for (int i = 0; i < 5000 && tl < 0; i++) begin @(posedge clk); if (!lock) tl = i; end
            tr = 0;
            do begin @(posedge clk); tr++; end
            while (!(link && phy.link && (an == 0 || (an_cpl && phy.st == 6))) && tr < 3000000);
            repeat (200) @(posedge clk);
            $display("TB_LOCK p=%0d lost_after=%0d relink=%0d link=%0d dut_speed=%0d an_starts=%0d phy_an_starts=%0d",
                     p, tl, tr, link, usx_speed, n_an_s, phy.n_an_start);
        end
    end
    $display("TB_CNT txf=%0d und=%0d abt=%0d good=%0d bad=%0d fcs=%0d runt=%0d over=%0d badblk=%0d seq=%0d rep=%0d an_s=%0d an_d=%0d keep_err=%0d tsc_err=%0d tx_ts=%0d",
             cnt[0], cnt[2], cnt[3], cnt[4], cnt[5], cnt[6], cnt[7], cnt[8], cnt[10], cnt[11], n_rep, n_an_s, n_an_d,
             keep_err, tsc_err, tx_ts_n);
    if ($value$plusargs("pr=%s", fn)) begin
        integer f;
        f = $fopen(fn, "w");
        foreach (phy.rxq[i]) $fdisplay(f, "%0d %0d %0d %s", phy.rxq[i].ok, phy.rxq[i].cyc, phy.rxq[i].lane,
                                       tb_bytes2hex(phy.rxq[i].b));
        $fclose(f);
    end
    if ($value$plusargs("ps=%s", fn)) begin
        integer f;
        f = $fopen(fn, "w");
        foreach (phy.sent_cyc[i]) $fdisplay(f, "%0d %0d %0d", phy.sent_cyc[i], phy.sent_lane[i],
                                            (i < phy.sent_corrupt.size()) ? phy.sent_corrupt[i] : 0);
        $fclose(f);
    end
    if (fo) $fclose(fo);
    if (fr) $fclose(fr);
    if (ft) $fclose(ft);
    $display("TB_DONE");
    $finish;
end

endmodule
