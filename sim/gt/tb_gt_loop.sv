// SPDX-License-Identifier: MIT
//
// tb_gt_loop - transceiver-level loop of the per-lane quad wrappers with the
// vendor's GT simulation models: two omac_10g on omac_gt_versal_gty_quad
// (VERSAL = 1, Versal GTYE5), omac_gt_usp_gty_quad (GTY = 1) or
// omac_gt_usp_gth_quad (GTY = 0), NLANES = 2, the serial pins crossed like a
// cable between the two ports (lane 0 TX -> lane 1 RX, lane 1 TX -> lane 0 RX).
// Checks: the transceiver comes out of reset from the 156.25 MHz reference
// clock, both lanes reach block lock and link up through the real 64B/66B
// gearbox, bit order and slip, and NFRAMES frames each way arrive complete,
// in order and without error (FCS, bad blocks). Run by sim/gt/run_gt_sim.tcl.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_gt_loop #(
    parameter bit       GTY        = 1'b1,
    parameter bit       VERSAL     = 1'b0,
    parameter bit [7:0] CH_OF_LANE = 8'h04,
    parameter int       NFRAMES    = 12,
    parameter int       LINK_US    = 600       // link-up time limit (simulated us)
);

localparam int NL = 2;

// ---------------- clocks ----------------
logic refclk = 1'b0, freerun = 1'b0;
always #3.2 refclk = ~refclk;       // 156.25 MHz
always #5.0 freerun = ~freerun;     // 100 MHz
logic reset_all = 1'b1;

// ---------------- transceiver wrapper ----------------
wire [NL-1:0]    txp, txn, rxp, rxn;
assign rxp = {txp[0], txp[1]};      // crossed: lane 0 <-> lane 1
assign rxn = {txn[0], txn[1]};
wire             clk, tx_ready;
wire [NL-1:0]    rx_clk, rx_ready, rx_valid, rx_slip, rx_reset_req, pg, cdr;
wire [2*NL-1:0]  tx_hdr, rx_hdr;
wire [64*NL-1:0] tx_data, rx_data;
wire [3*NL-1:0]  loopback;
wire             qpll_lock, refclk_mon;

if (VERSAL) begin : g_versal
    omac_gt_versal_gty_quad #(.NLANES(NL), .CH_OF_LANE(CH_OF_LANE)) dut (
        .refclk_p(refclk), .refclk_n(~refclk), .freerun_clk(freerun), .reset_all(reset_all),
        .gty_rxp(rxp), .gty_rxn(rxn), .gty_txp(txp), .gty_txn(txn),
        .tx_usrclk2(clk), .gt_tx_ready(tx_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data),
        .rx_usrclk2(rx_clk), .gt_rx_ready(rx_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
        .gt_rx_data(rx_data), .gt_rx_slip(rx_slip), .gt_rx_reset_req(rx_reset_req), .gt_loopback(loopback),
        .tx_polarity('0), .rx_polarity('0), .tx_diffctrl({NL{5'd25}}), .tx_postcursor('0),
        .tx_precursor('0), .rx_lpmen({NL{1'b1}}),
        .drp_addr('0), .drp_di('0), .drp_en('0), .drp_we('0), .drp_do(), .drp_rdy(),
        .gt_powergood(pg), .qpll_lock(qpll_lock), .rx_cdr_lock(cdr), .rx_reset_busy(), .refclk_mon(refclk_mon),
        .apb_paddr('0), .apb_psel(1'b0), .apb_penable(1'b0), .apb_pwrite(1'b0), .apb_pwdata('0),
        .apb_prdata(), .apb_pready(), .apb_pslverr());
end else if (GTY) begin : g_gty
    omac_gt_usp_gty_quad #(.NLANES(NL), .CH_OF_LANE(CH_OF_LANE)) dut (
        .refclk_p(refclk), .refclk_n(~refclk), .freerun_clk(freerun), .reset_all(reset_all),
        .gty_rxp(rxp), .gty_rxn(rxn), .gty_txp(txp), .gty_txn(txn),
        .tx_usrclk2(clk), .gt_tx_ready(tx_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data),
        .rx_usrclk2(rx_clk), .gt_rx_ready(rx_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
        .gt_rx_data(rx_data), .gt_rx_slip(rx_slip), .gt_rx_reset_req(rx_reset_req), .gt_loopback(loopback),
        .tx_polarity('0), .rx_polarity('0), .tx_diffctrl({NL{5'b11000}}), .tx_postcursor('0),
        .tx_precursor('0), .rx_lpmen({NL{1'b1}}),
        .drp_addr('0), .drp_di('0), .drp_en('0), .drp_we('0), .drp_do(), .drp_rdy(),
        .gt_powergood(pg), .qpll_lock(qpll_lock), .rx_cdr_lock(cdr), .rx_reset_busy(), .refclk_mon(refclk_mon));
end else begin : g_gth
    omac_gt_usp_gth_quad #(.NLANES(NL), .CH_OF_LANE(CH_OF_LANE)) dut (
        .refclk_p(refclk), .refclk_n(~refclk), .freerun_clk(freerun), .reset_all(reset_all),
        .gth_rxp(rxp), .gth_rxn(rxn), .gth_txp(txp), .gth_txn(txn),
        .tx_usrclk2(clk), .gt_tx_ready(tx_ready), .gt_tx_hdr(tx_hdr), .gt_tx_data(tx_data),
        .rx_usrclk2(rx_clk), .gt_rx_ready(rx_ready), .gt_rx_valid(rx_valid), .gt_rx_hdr(rx_hdr),
        .gt_rx_data(rx_data), .gt_rx_slip(rx_slip), .gt_rx_reset_req(rx_reset_req), .gt_loopback(loopback),
        .tx_polarity('0), .rx_polarity('0), .tx_diffctrl({NL{5'b11000}}), .tx_postcursor('0),
        .tx_precursor('0), .rx_lpmen({NL{1'b1}}),
        .drp_addr('0), .drp_di('0), .drp_en('0), .drp_we('0), .drp_do(), .drp_rdy(),
        .gt_powergood(pg), .qpll_lock(qpll_lock), .rx_cdr_lock(cdr), .rx_reset_busy(), .refclk_mon(refclk_mon));
end

// ---------------- two MACs ----------------
logic [NL-1:0]   rst = '1;
logic [63:0]     s_tdata [NL];
logic [7:0]      s_tkeep [NL];
logic [NL-1:0]   s_tvalid = '0, s_tlast = '0;
wire  [NL-1:0]   s_tready;
wire  [63:0]     m_tdata [NL];
wire  [7:0]      m_tkeep [NL];
wire  [NL-1:0]   m_tvalid, m_tlast, m_tuser, link_up, block_lock;
wire  [NL-1:0]   ev_fcs, ev_bad_block, ev_good;

for (genvar l = 0; l < NL; l++) begin : g_mac
    omac_10g #(.SLIP_WAIT(64)) u_mac (
        .clk(clk), .rst(rst[l]),
        .s_axis_tx_tdata(s_tdata[l]), .s_axis_tx_tkeep(s_tkeep[l]), .s_axis_tx_tvalid(s_tvalid[l]),
        .s_axis_tx_tready(s_tready[l]), .s_axis_tx_tlast(s_tlast[l]), .s_axis_tx_tuser(1'b0),
        .m_axis_rx_tdata(m_tdata[l]), .m_axis_rx_tkeep(m_tkeep[l]), .m_axis_rx_tvalid(m_tvalid[l]),
        .m_axis_rx_tlast(m_tlast[l]), .m_axis_rx_tuser(m_tuser[l]),
        .ctl_tx_enable(1'b1), .ctl_rx_enable(1'b1), .ctl_loopback(1'b0), .ctl_tx_fault(1'b0),
        .ctl_pause_tx_honour(1'b0), .ctl_tx_pause_send(1'b0), .ctl_tx_pause_quanta(16'hFFFF),
        .ctl_tx_pause_refresh(16'h8000), .ctl_mac_addr(48'h02_00_00_00_00_10 + l),
        .stat_link_up(link_up[l]), .stat_block_lock(block_lock[l]), .stat_hi_ber(), .stat_local_fault(),
        .stat_remote_fault(), .stat_rx_pause_req(), .stat_rx_pause_quanta(), .stat_tx_pause_active(),
        .ev_tx_frame(), .ev_tx_pause(), .ev_tx_underflow(), .ev_tx_abort(), .ev_rx_frame_good(ev_good[l]),
        .ev_rx_frame_bad(), .ev_rx_fcs_error(ev_fcs[l]), .ev_rx_runt(), .ev_rx_oversize(), .ev_rx_pause(),
        .ev_rx_bad_block(ev_bad_block[l]), .ev_rx_sequence_error(),
        .gt_tx_ready(tx_ready), .gt_tx_hdr(tx_hdr[2*l +: 2]), .gt_tx_data(tx_data[64*l +: 64]),
        .gt_loopback(loopback[3*l +: 3]),
        .gt_rx_clk(rx_clk[l]), .gt_rx_ready(rx_ready[l]), .gt_rx_valid(rx_valid[l]), .gt_rx_hdr(rx_hdr[2*l +: 2]),
        .gt_rx_data(rx_data[64*l +: 64]), .gt_rx_slip(rx_slip[l]), .gt_rx_reset_req(rx_reset_req[l]),
        .tx_ts_in('0), .tx_ts_valid(), .tx_ts_val(), .tx_ts_lane4(), .tx_ts_user(), .rx_ts_in('0),
        .m_axis_rx_ts(), .m_axis_rx_ts_lane4(),
        .ctl_usx_an_enable(1'b0), .ctl_usx_an_restart(1'b0), .ctl_usx_an_adv('0), .ctl_usx_speed('0),
        .ctl_usx_link_timer('0), .ctl_usx_rx_strict(1'b0), .stat_usx_an_complete(), .stat_usx_an_state(),
        .stat_usx_lp_word(), .stat_usx_speed(), .stat_usx_link_ok(), .ev_usx_an_start(), .ev_usx_an_done(),
        .ev_usx_rep_error());
end

// ---------------- frames: length and byte pattern per (sender, index) ----------------
function automatic int flen(input int src, input int k);
    return 60 + ((k * 397 + src * 131) % 1400);
endfunction
function automatic logic [7:0] fbyte(input int src, input int k, input int i);
    return 8'((src * 89 + k * 7 + i * 13) & 8'hFF);
endfunction

// transmitters (port l sends NFRAMES frames to the other port), back to back
logic [NL-1:0] tx_go = '0, tx_done = '0;
for (genvar l = 0; l < NL; l++) begin : g_tx
    int k = 0, b = 0;
    initial begin s_tdata[l] = '0; s_tkeep[l] = '0; end
    always @(posedge clk) begin
        if (tx_go[l] && !tx_done[l] && (!s_tvalid[l] || s_tready[l])) begin
            if (k < NFRAMES) begin
                automatic int len = flen(l, k);
                s_tvalid[l] <= 1'b1;
                for (int j = 0; j < 8; j++) begin
                    s_tdata[l][8*j +: 8] <= (b + j < len) ? fbyte(l, k, b + j) : 8'h00;
                    s_tkeep[l][j]        <= (b + j < len);
                end
                s_tlast[l] <= (b + 8 >= len);
                if (b + 8 >= len) begin
                    k <= k + 1;
                    b <= 0;
                end else b <= b + 8;
            end else begin
                s_tvalid[l] <= 1'b0;
                tx_done[l]  <= 1'b1;
            end
        end
    end
end

// receivers: port r receives from port 1 - r
int rx_frames [NL];
int rx_errors [NL];
for (genvar r = 0; r < NL; r++) begin : g_rx
    initial begin
        automatic int k = 0, pos = 0;
        rx_frames[r] = 0; rx_errors[r] = 0;
        forever begin
            @(posedge clk);
            if (m_tvalid[r]) begin
                for (int j = 0; j < 8; j++) if (m_tkeep[r][j]) begin
                    if (m_tdata[r][8*j +: 8] !== fbyte(1 - r, k, pos)) begin
                        if (rx_errors[r] < 5) $display("TB_MISMATCH port=%0d frame=%0d byte=%0d got=%02x exp=%02x",
                                                       r, k, pos, m_tdata[r][8*j +: 8], fbyte(1 - r, k, pos));
                        rx_errors[r]++;
                    end
                    pos++;
                end
                if (m_tlast[r]) begin
                    if (m_tuser[r] || pos != flen(1 - r, k)) begin
                        $display("TB_BADFRAME port=%0d frame=%0d len=%0d exp=%0d tuser=%0d", r, k, pos, flen(1 - r, k), m_tuser[r]);
                        rx_errors[r]++;
                    end
                    rx_frames[r]++;
                    k++;
                    pos = 0;
                end
            end
        end
    end
end

int fcs_err = 0, bad_blocks = 0, bad0 = 0, bad1 = 0;
always @(posedge clk) begin
    if (|link_up) begin
        fcs_err    <= fcs_err + ev_fcs[0] + ev_fcs[1];
        bad_blocks <= bad_blocks + ((&link_up) ? (ev_bad_block[0] + ev_bad_block[1]) : 0);
        bad0       <= bad0 + ((&link_up) ? ev_bad_block[0] : 0);
        bad1       <= bad1 + ((&link_up) ? ev_bad_block[1] : 0);
    end
end

// ---------------- wire check: bit order on the serial line ----------------
// A loop between two lanes of one wrapper cannot see a wrong bit order (both ends would
// reverse alike), so lane 0's transmit pin is decoded here independently: the serial bits
// (from the transition times, one unit interval = 1 / 10.3125 GHz), the 66-bit block
// alignment (the one where the two sync header bits always differ), then per IEEE 802.3
// clause 49: an idle line is control blocks only, sync header "10" in transmission order,
// and the descrambled payload (x^58 + x^39 + 1, in transmission order) is block type 0x1E
// sent bit 0 first followed by eight 7-bit idle characters (all zero).
localparam realtime UI     = 1.0 / 10.3125;   // ns
localparam int      WBITS  = 66 * 64;
bit      wire_bits [$];
bit      cap_on = 1'b0, cap_started = 1'b0, v_last = 1'b0;
realtime t_last = 0.0;
always @(txp[0]) begin
    if (cap_on && wire_bits.size() < WBITS) begin
        if (!cap_started) begin
            cap_started = 1'b1;
        end else begin
            automatic int n = $rtoi(($realtime - t_last) / UI + 0.5);
            for (int i = 0; i < n; i++) wire_bits.push_back(v_last);
        end
        t_last = $realtime;
        v_last = txp[0];
    end
end
int wire_off = -1, wire_ctrl = 0, wire_idle_ok = 0, wire_blocks = 0;
task automatic wire_analyse();
    automatic int nb = wire_bits.size() / 66 - 1;
    automatic bit [57:0] sr = '0;
    for (int off = 0; off < 66 && wire_off < 0; off++) begin
        automatic bit ok = 1'b1;
        for (int k = 0; k < nb; k++) if (wire_bits[off + 66*k] == wire_bits[off + 66*k + 1]) ok = 1'b0;
        if (ok) wire_off = off;
    end
    if (wire_off < 0) return;
    wire_blocks = nb;
    for (int k = 0; k < nb; k++) begin
        automatic int    b0 = wire_off + 66*k;
        automatic bit [63:0] pl;
        if (wire_bits[b0] == 1'b1 && wire_bits[b0 + 1] == 1'b0) wire_ctrl++;
        for (int j = 0; j < 64; j++) begin
            automatic bit sb = wire_bits[b0 + 2 + j];
            pl[j] = sb ^ sr[38] ^ sr[57];
            sr = {sr[56:0], sb};
        end
        if (k >= 1 && pl == 64'h1E) wire_idle_ok++;
    end
endtask

// ---------------- sequence ----------------
initial begin
    automatic time t0;
    #1000;
    reset_all = 1'b0;
    $display("TB_INFO reset_all released t_ns=%0d", $time);
    fork
        begin
            wait (tx_ready);
            $display("TB_EVENT gt_tx_ready t_ns=%0d qpll_lock=%0d powergood=%b", $time, qpll_lock, pg);
            @(posedge clk);
            rst <= '0;
            wait (&rx_ready);
            $display("TB_EVENT gt_rx_ready t_ns=%0d cdr_lock=%b", $time, cdr);
            wait (&block_lock);
            $display("TB_EVENT block_lock t_ns=%0d", $time);
            wait (&link_up);
            $display("TB_EVENT link_up t_ns=%0d", $time);
        end
        begin
            #(LINK_US * 1us);
        end
    join_any
    disable fork;
    if (!(&link_up)) begin
        $display("TB_RESULT pass=0 reason=no_link tx_ready=%0d rx_ready=%b block_lock=%b link_up=%b t_ns=%0d",
                 tx_ready, rx_ready, block_lock, link_up, $time);
        $finish;
    end
    repeat (200) @(posedge clk);
    // idle line: capture lane 0's serial transmit stream and decode it
    cap_on = 1'b1;
    wait (wire_bits.size() >= WBITS);
    cap_on = 1'b0;
    wire_analyse();
    begin
        automatic int fd = $fopen("wire_lane0.txt", "w");
        foreach (wire_bits[i]) $fwrite(fd, "%0d", wire_bits[i]);
        $fclose(fd);
    end
    $display("TB_WIRE bits=%0d block_offset=%0d blocks=%0d control_10=%0d idle_payload_ok=%0d",
             wire_bits.size(), wire_off, wire_blocks, wire_ctrl, wire_idle_ok);
    t0 = $time;
    tx_go = '1;
    fork
        wait ((rx_frames[0] >= NFRAMES) && (rx_frames[1] >= NFRAMES));
        #(200us);
    join_any
    disable fork;
    repeat (100) @(posedge clk);
    $display("TB_FRAMES rx0=%0d rx1=%0d err0=%0d err1=%0d fcs=%0d bad_blocks=%0d (port 0 %0d, port 1 %0d) us=%0d",
             rx_frames[0], rx_frames[1], rx_errors[0], rx_errors[1], fcs_err, bad_blocks, bad0, bad1,
             ($time - t0) / 1000);
    $display("TB_RESULT pass=%0d", (rx_frames[0] == NFRAMES) && (rx_frames[1] == NFRAMES) &&
             (rx_errors[0] == 0) && (rx_errors[1] == 0) && (fcs_err == 0) && (bad_blocks == 0) && (&link_up) &&
             (wire_off >= 0) && (wire_ctrl == wire_blocks) && (wire_idle_ok == wire_blocks - 1));
    $finish;
end

endmodule

`default_nettype wire
