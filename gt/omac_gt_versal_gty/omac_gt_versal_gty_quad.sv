// SPDX-License-Identifier: MIT
//
// omac_gt_versal_gty_quad - one to four channels of one Versal GTY (GTYE5)
// quad as INDEPENDENT 10GBASE-R lanes, one omac_10g per lane: the Versal
// counterpart of omac_gt_usp_gty_quad / omac_gt_usp_gth_quad with the same
// parameters, ports and per-lane behaviour, so a design can take any of them
// with a generate branch on the transceiver type. The transceiver is AMD's free
// gt_quad_base IP made by gt/omac_gt_versal_gty/gen_gt.tcl
// omac_gen_versal_gty_quad (module omac_versal_gty_quad: one protocol per lane,
// preset 10GBASE-R with RPLL, 64B/66B asynchronous gearbox, internal and user
// width 64, so the user clock is the 156.25 MHz block clock).
// Features:
//   * NLANES (1-4) lanes; lane l uses quad channel CH_OF_LANE[2l +: 2] (the
//     channel number itself: on Versal the IP always spans the four channels of
//     the quad; channels without a lane are left unconnected and powered down).
//   * resets: the Versal channel's own reset sequencer (master resets
//     TXMSTRESET / RXMSTRESET in sequential mode) driven by a small controller
//     on freerun_clk: hold the master resets until reset_all is released and the
//     quad reports power good, start the user clocks, assert USERRDY 32 cycles
//     after the user clock runs, wait for MSTRESETDONE.
//   * per-lane RX reset: gt_rx_reset_req[l] pulses that channel's
//     RXMSTDATAPATHRESET only (the receive datapath, PMA and PCS, without the
//     shared PLL), so a lane without signal never disturbs the others;
//     gt_rx_ready[l] is per lane. A lane whose receiver does not report
//     MSTRESETDONE within DONE_HIGH_CYCLES restarts its datapath by itself.
//   * bit order: the Versal gearbox sends bit 0 of TXDATA / TXHEADER first, i.e. in
//     IEEE 802.3 order: no reversal (BIT_REVERSE = 0, unlike the UltraScale+ wrappers).
//   * per-lane loopback, polarity and transmit driver settings (Versal GTY
//     codes; TX_MAINCURSOR as a parameter).
//   * TX: one user clock for all lanes (the master lane's TXOUTCLK =
//     TXPROGDIVCLK 156.25 MHz through one BUFG_GT), derived from the quad's RPLL
//     and therefore from the reference clock alone: tx_usrclk2 = the clk of every
//     omac_10g. Every lane transmits at the reference clock's frequency (a
//     SyncE-traceable line clock when the reference clock comes from a SyncE
//     DPLL). TX buffer on, so every lane runs from the master's user clock.
//   * RX: every lane has its own user clock from its own RXOUTCLK (recovered
//     clock, one BUFG_GT per lane): rx_usrclk2[l] = omac gt_rx_clk of lane l.
//   * status: qpll_lock (= the RPLL lock of the used HSCLK(s); the name is kept
//     from the UltraScale+ wrappers), per-lane rx_cdr_lock and rx_reset_busy.
//   * refclk_mon: the reference clock / 8 (IBUFDS_GTE5 ODIV2 -> BUFG_GT),
//     running whenever the reference clock does, for a frequency monitor.
//   * register access: Versal transceivers have no per-channel DRP; the quad's
//     APB3 port is brought out (apb_*, on freerun_clk). The drp_* ports exist
//     for port compatibility with the UltraScale+ wrappers only: drp_do = 0 and
//     drp_rdy answers every drp_en one cycle later.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_gt_versal_gty_quad #(
    parameter int       NLANES           = 2,          // lanes (1-4, one quad)
    parameter bit       BIT_REVERSE      = 1'b0,       // the Versal gearbox sends bit 0 first (see the docs)
    parameter bit [7:0] CH_OF_LANE       = 8'hE4,      // lane 3..0 -> quad channel 3..0
    parameter bit [6:0] TX_MAINCURSOR    = 7'd77,      // TXMAINCURSOR of every lane
    parameter int       RST_CYCLES       = 32,         // freerun_clk cycles of a master / datapath reset pulse
    parameter int       DONE_LOW_CYCLES  = 4096,       // wait for RXMSTRESETDONE to fall after a datapath reset
    parameter int       DONE_HIGH_CYCLES = 1048576,    // wait for MSTRESETDONE (10 ms at 100 MHz), then retry
    parameter           SIM_DEVICE       = "VERSAL_AI_CORE"   // BUFG_GT simulation model
) (
    input  wire logic                   refclk_p,
    input  wire logic                   refclk_n,
    input  wire logic                   freerun_clk,
    input  wire logic                   reset_all,

    // serial pins, by lane (the quad comes from the pin constraints)
    input  wire logic [NLANES-1:0]      gty_rxp,
    input  wire logic [NLANES-1:0]      gty_rxn,
    output wire logic [NLANES-1:0]      gty_txp,
    output wire logic [NLANES-1:0]      gty_txn,

    // omac GT side, by lane
    output wire logic                   tx_usrclk2,      // = clk of every omac_10g
    output wire logic                   gt_tx_ready,
    input  wire logic [2*NLANES-1:0]    gt_tx_hdr,
    input  wire logic [64*NLANES-1:0]   gt_tx_data,
    output wire logic [NLANES-1:0]      rx_usrclk2,      // = omac gt_rx_clk, per lane
    output logic      [NLANES-1:0]      gt_rx_ready,
    output wire logic [NLANES-1:0]      gt_rx_valid,
    output wire logic [2*NLANES-1:0]    gt_rx_hdr,
    output wire logic [64*NLANES-1:0]   gt_rx_data,
    input  wire logic [NLANES-1:0]      gt_rx_slip,
    input  wire logic [NLANES-1:0]      gt_rx_reset_req,  // per lane, any clock (a pulse >= 2 freerun_clk cycles or a level)
    input  wire logic [3*NLANES-1:0]    gt_loopback,      // lane l at [3l +: 3]

    // transceiver settings, by lane (static)
    input  wire logic [NLANES-1:0]      tx_polarity,
    input  wire logic [NLANES-1:0]      rx_polarity,
    input  wire logic [5*NLANES-1:0]    tx_diffctrl,      // lane l at [5l +: 5] (Versal GTY codes)
    input  wire logic [5*NLANES-1:0]    tx_postcursor,
    input  wire logic [5*NLANES-1:0]    tx_precursor,
    input  wire logic [NLANES-1:0]      rx_lpmen,         // 0: DFE (cables), 1: LPM

    // DRP, by lane: not present on Versal (see the header); tie drp_en / drp_we to 0
    input  wire logic [10*NLANES-1:0]   drp_addr,
    input  wire logic [16*NLANES-1:0]   drp_di,
    input  wire logic [NLANES-1:0]      drp_en,
    input  wire logic [NLANES-1:0]      drp_we,
    output wire logic [16*NLANES-1:0]   drp_do,
    output logic      [NLANES-1:0]      drp_rdy,

    output wire logic [NLANES-1:0]      gt_powergood,
    output wire logic                   qpll_lock,
    output wire logic [NLANES-1:0]      rx_cdr_lock,
    output logic      [NLANES-1:0]      rx_reset_busy,
    output wire logic                   refclk_mon,

    // the quad's APB3 register port (freerun_clk); tie apb_psel to 0 when unused
    input  wire logic [15:0]            apb_paddr,
    input  wire logic                   apb_psel,
    input  wire logic                   apb_penable,
    input  wire logic                   apb_pwrite,
    input  wire logic [31:0]            apb_pwdata,
    output wire logic [31:0]            apb_prdata,
    output wire logic                   apb_pready,
    output wire logic                   apb_pslverr
);

localparam int N = NLANES;

if (N < 1 || N > 4) begin : g_bad_nlanes
    $error("omac_gt_versal_gty_quad: NLANES must be 1-4");
end

// channels in use, and the HSCLK (PLL pair) each needs: channels 0/1 = HSCLK0, 2/3 = HSCLK1
function automatic logic [3:0] used_mask();
    logic [3:0] m = '0;
    for (int l = 0; l < N; l++) m[CH_OF_LANE[2*l +: 2]] = 1'b1;
    return m;
endfunction
localparam logic [3:0] USED = used_mask();
localparam int         MC   = CH_OF_LANE[1:0];       // master channel (lane 0)

if ($countones(USED) != N) begin : g_bad_map
    $error("omac_gt_versal_gty_quad: CH_OF_LANE maps two lanes to one channel");
end

wire refclk, refclk_odiv2;
IBUFDS_GTE5 #(
    .REFCLK_EN_TX_PATH (1'b0),
    .REFCLK_HROW_CK_SEL(0),                 // ODIV2 = O
    .REFCLK_ICNTL_RX   (0)
) u_refclk_buf (.I(refclk_p), .IB(refclk_n), .CEB(1'b0), .O(refclk), .ODIV2(refclk_odiv2));
BUFG_GT #(.SIM_DEVICE(SIM_DEVICE)) u_refclk_mon (.CE(1'b1), .CEMASK(1'b0), .CLR(1'b0), .CLRMASK(1'b0),
    .DIV(3'd7), .I(refclk_odiv2), .O(refclk_mon));

// ---------------- per-channel vectors of the quad (channel index c) ----------------
wire  [128*4-1:0] txdata_c;
wire  [128*4-1:0] rxdata_c;
wire  [6*4-1:0]   txheader_c;
wire  [6*4-1:0]   rxheader_c;
wire  [2*4-1:0]   rxdatavalid_c, rxheadervalid_c;
wire  [3:0]       rxslip_c, rxpol_c, txpol_c, lpm_c, rxp_c, rxn_c;
wire  [3:0]       txp_c, txn_c;
wire  [3*4-1:0]   lb_c;
wire  [5*4-1:0]   diff_c, post_c, pre_c;
wire  [3:0]       txoutclk_c, rxoutclk_c;
wire  [3:0]       txusrclk_c, rxusrclk_c;
wire  [3:0]       txmstreset_c, rxmstreset_c, rxdpreset_c, txuserrdy_c, rxuserrdy_c;
wire  [3:0]       txmstresetdone_c, rxmstresetdone_c;
wire  [3:0]       txprogdivresetdone_c, rxprogdivresetdone_c, txpmaresetdone_c, rxpmaresetdone_c;
wire  [3:0]       rxcdrlock_c;
wire  [1:0]       rplllock;
wire              gtpowergood;

// synchronised quad status (freerun_clk)
logic pg_s, rst_s, txact_s;
logic [3:0] txdone_s;
omac_sync_bit #(.WIDTH(2)) u_sync_q (.clk(freerun_clk), .din({gtpowergood, reset_all}), .dout({pg_s, rst_s}));
omac_sync_bit #(.WIDTH(4)) u_sync_txd (.clk(freerun_clk), .din(txmstresetdone_c), .dout(txdone_s));

// ---------------- TX user clock (master lane), shared by every lane ----------------
wire tx_clr = !(txprogdivresetdone_c[MC] && txpmaresetdone_c[MC]);
BUFG_GT #(.SIM_DEVICE(SIM_DEVICE)) u_txusrclk (.CE(1'b1), .CEMASK(1'b0), .CLR(tx_clr), .CLRMASK(1'b0),
    .DIV(3'd0), .I(txoutclk_c[MC]), .O(tx_usrclk2));
(* ASYNC_REG = "TRUE" *) logic txa_meta = 1'b0, txa = 1'b0;
always_ff @(posedge tx_usrclk2 or posedge tx_clr) begin
    if (tx_clr) begin
        txa_meta <= 1'b0;
        txa      <= 1'b0;
    end else begin
        txa_meta <= 1'b1;
        txa      <= txa_meta;
    end
end
omac_sync_bit u_sync_txa (.clk(freerun_clk), .din(txa), .dout(txact_s));

// ---------------- TX reset controller (freerun_clk), all lanes together ----------------
typedef enum logic [2:0] { T_RST, T_REL, T_WCLK, T_DLY, T_RDY, T_DONE } tst_t;
tst_t        tst = T_RST;
logic [20:0] ttmr = '0;
logic        tx_mst = 1'b1, tx_urdy = 1'b0, tx_done = 1'b0;
always_ff @(posedge freerun_clk) begin
    case (tst)
        T_RST: begin
            tx_mst  <= 1'b1;
            tx_urdy <= 1'b0;
            if (pg_s) begin
                tst  <= T_REL;
                ttmr <= 21'(RST_CYCLES);
            end
        end
        T_REL: if (ttmr == '0) begin
            tx_mst <= 1'b0;
            tst    <= T_WCLK;
        end else ttmr <= ttmr - 1'b1;
        T_WCLK: begin
            tx_urdy <= 1'b0;
            if (txact_s) begin
                tst  <= T_DLY;
                ttmr <= 21'd31;
            end
        end
        T_DLY: if (!txact_s) tst <= T_WCLK;
               else if (ttmr == '0) begin
                   tx_urdy <= 1'b1;
                   tst     <= T_RDY;
                   ttmr    <= 21'(DONE_HIGH_CYCLES);
               end else ttmr <= ttmr - 1'b1;
        T_RDY: if (!txact_s) tst <= T_WCLK;
               else if ((txdone_s & USED) == USED) tst <= T_DONE;
               else if (ttmr == '0) tst <= T_RST;          // no reset done: start over
               else ttmr <= ttmr - 1'b1;
        default: if (!txact_s || (txdone_s & USED) != USED) tst <= T_WCLK;
    endcase
    if (rst_s || !pg_s) tst <= T_RST;
    tx_done <= (tst == T_DONE);
end
assign gt_tx_ready = tx_done && txact_s;

// ---------------- lanes ----------------
wire  [N-1:0] lane_rdy, lane_busy;
for (genvar l = 0; l < N; l++) begin : g_lane
    localparam int C = CH_OF_LANE[2*l +: 2];
    // data, bit order: the Versal GTY gearbox sends TXDATA / TXHEADER bit 0 first (IEEE
    // order, unlike the UltraScale+ gearbox); BIT_REVERSE = 1 would reverse as on UltraScale+
    for (genvar i = 0; i < 64; i++) begin : g_bits
        assign txdata_c[128*C + i]  = BIT_REVERSE ? gt_tx_data[64*l + 63 - i] : gt_tx_data[64*l + i];
        assign gt_rx_data[64*l + i] = BIT_REVERSE ? rxdata_c[128*C + 63 - i]  : rxdata_c[128*C + i];
    end
    assign txdata_c[128*C + 64 +: 64] = '0;
    assign txheader_c[6*C +: 6] = {4'd0, BIT_REVERSE ? {gt_tx_hdr[2*l], gt_tx_hdr[2*l+1]} : gt_tx_hdr[2*l +: 2]};
    assign gt_rx_hdr[2*l +: 2]  = BIT_REVERSE ? {rxheader_c[6*C], rxheader_c[6*C+1]} : rxheader_c[6*C +: 2];
    assign gt_rx_valid[l]       = rxdatavalid_c[2*C] && rxheadervalid_c[2*C];
    assign rxslip_c[C]          = gt_rx_slip[l];
    assign rxpol_c[C]           = rx_polarity[l];
    assign txpol_c[C]           = tx_polarity[l];
    assign lpm_c[C]             = rx_lpmen[l];
    assign lb_c[3*C +: 3]       = gt_loopback[3*l +: 3];
    assign diff_c[5*C +: 5]     = tx_diffctrl[5*l +: 5];
    assign post_c[5*C +: 5]     = tx_postcursor[5*l +: 5];
    assign pre_c[5*C +: 5]      = tx_precursor[5*l +: 5];
    assign rxp_c[C]             = gty_rxp[l];
    assign rxn_c[C]             = gty_rxn[l];
    assign gty_txp[l]           = txp_c[C];
    assign gty_txn[l]           = txn_c[C];
    assign gt_powergood[l]      = gtpowergood;
    assign rx_cdr_lock[l]       = rxcdrlock_c[C];
    assign txusrclk_c[C]        = tx_usrclk2;
    assign txmstreset_c[C]      = tx_mst;
    assign txuserrdy_c[C]       = tx_urdy;
    assign drp_do[16*l +: 16]   = 16'd0;

    // RX user clock of this lane (its own recovered clock)
    wire rx_clr = !(rxprogdivresetdone_c[C] && rxpmaresetdone_c[C]);
    BUFG_GT #(.SIM_DEVICE(SIM_DEVICE)) u_rxusrclk (.CE(1'b1), .CEMASK(1'b0), .CLR(rx_clr), .CLRMASK(1'b0),
        .DIV(3'd0), .I(rxoutclk_c[C]), .O(rxusrclk_c[C]));
    assign rx_usrclk2[l] = rxusrclk_c[C];
    (* ASYNC_REG = "TRUE" *) logic rxa_meta = 1'b0, rxa = 1'b0;
    always_ff @(posedge rxusrclk_c[C] or posedge rx_clr) begin
        if (rx_clr) begin
            rxa_meta <= 1'b0;
            rxa      <= 1'b0;
        end else begin
            rxa_meta <= 1'b1;
            rxa      <= rxa_meta;
        end
    end

    // RX reset controller of this lane (freerun_clk)
    logic req_s, done_s, act_s, req_d = 1'b0;
    omac_sync_bit #(.WIDTH(3)) u_sync (.clk(freerun_clk),
        .din({gt_rx_reset_req[l], rxmstresetdone_c[C], rxa}), .dout({req_s, done_s, act_s}));
    typedef enum logic [2:0] { R_RST, R_REL, R_WCLK, R_DLY, R_RDY, R_DONE, R_DP, R_WLOW } rst_t;
    rst_t        rs = R_RST;
    logic [20:0] rtmr = '0;
    logic        r_mst = 1'b1, r_dp = 1'b0, r_urdy = 1'b0;
    always_ff @(posedge freerun_clk) begin
        req_d <= req_s;
        case (rs)
            R_RST: begin
                r_mst  <= 1'b1;
                r_dp   <= 1'b0;
                r_urdy <= 1'b0;
                if (pg_s) begin
                    rs   <= R_REL;
                    rtmr <= 21'(RST_CYCLES);
                end
            end
            R_REL: if (rtmr == '0) begin
                r_mst <= 1'b0;
                rs    <= R_WCLK;
            end else rtmr <= rtmr - 1'b1;
            R_WCLK: begin
                r_urdy <= 1'b0;
                if (act_s) begin
                    rs   <= R_DLY;
                    rtmr <= 21'd31;
                end
            end
            R_DLY: if (!act_s) rs <= R_WCLK;
                   else if (rtmr == '0) begin
                       r_urdy <= 1'b1;
                       rs     <= R_RDY;
                       rtmr   <= 21'(DONE_HIGH_CYCLES);
                   end else rtmr <= rtmr - 1'b1;
            R_RDY: if (!act_s) rs <= R_WCLK;
                   else if (done_s) rs <= R_DONE;
                   else if (rtmr == '0) begin          // no reset done: restart the datapath
                       rs   <= R_DP;
                       rtmr <= 21'(RST_CYCLES);
                   end else rtmr <= rtmr - 1'b1;
            R_DONE: if (req_s && !req_d) begin
                       rs   <= R_DP;
                       rtmr <= 21'(RST_CYCLES);
                   end else if (!act_s || !done_s) rs <= R_WCLK;
            R_DP: begin
                r_dp   <= 1'b1;
                r_urdy <= 1'b0;
                if (rtmr == '0) begin
                    r_dp <= 1'b0;
                    rs   <= R_WLOW;
                    rtmr <= 21'(DONE_LOW_CYCLES);
                end else rtmr <= rtmr - 1'b1;
            end
            default: if (!done_s || rtmr == '0) rs <= R_WCLK;   // R_WLOW
                     else rtmr <= rtmr - 1'b1;
        endcase
        if (rst_s || !pg_s) rs <= R_RST;
    end
    assign rxmstreset_c[C] = r_mst;
    assign rxdpreset_c[C]  = r_dp;
    assign rxuserrdy_c[C]  = r_urdy;
    assign lane_rdy[l]  = (rs == R_DONE) && done_s && act_s;
    assign lane_busy[l] = (rs != R_DONE);
end
always_ff @(posedge freerun_clk) begin
    gt_rx_ready   <= lane_rdy;
    rx_reset_busy <= lane_busy;
    drp_rdy       <= drp_en;
end

// ---------------- channels without a lane ----------------
for (genvar c = 0; c < 4; c++) begin : g_unused
    if (!USED[c]) begin : g_tie
        assign txdata_c[128*c +: 128] = '0;
        assign txheader_c[6*c +: 6]   = '0;
        assign rxslip_c[c]     = 1'b0;
        assign rxpol_c[c]      = 1'b0;
        assign txpol_c[c]      = 1'b0;
        assign lpm_c[c]        = 1'b0;
        assign lb_c[3*c +: 3]  = '0;
        assign diff_c[5*c +: 5] = 5'd25;
        assign post_c[5*c +: 5] = '0;
        assign pre_c[5*c +: 5]  = '0;
        assign rxp_c[c]        = 1'b0;
        assign rxn_c[c]        = 1'b1;
        assign txusrclk_c[c]   = 1'b0;
        assign rxusrclk_c[c]   = 1'b0;
        assign txmstreset_c[c] = 1'b0;
        assign rxmstreset_c[c] = 1'b0;
        assign rxdpreset_c[c]  = 1'b0;
        assign txuserrdy_c[c]  = 1'b0;
        assign rxuserrdy_c[c]  = 1'b0;
    end
end

// qpll_lock: the RPLL of every HSCLK in use
assign qpll_lock = (!(|USED[1:0]) || rplllock[0]) && (!(|USED[3:2]) || rplllock[1]);

// ---------------- the gt_quad_base instance ----------------
// Every input of the IP is connected: the used ports to the vectors above, the rest to
// the IP's own default values (gt_quad_base 1.1). An input left open would float in
// simulation.
`define OMAC_VGTQ_CH(c) \
    .ch``c``_txdata(txdata_c[128*c +: 128]), \
    .ch``c``_txheader(txheader_c[6*c +: 6]), \
    .ch``c``_txsequence(7'd0), \
    .ch``c``_gttxreset(1'd0), \
    .ch``c``_txprogdivreset(1'd0), \
    .ch``c``_txuserrdy(txuserrdy_c[c]), \
    .ch``c``_txphalignresetmask(2'd3), \
    .ch``c``_txcominit(1'd0), \
    .ch``c``_txcomsas(1'd0), \
    .ch``c``_txcomwake(1'd0), \
    .ch``c``_txdapicodeovrden(1'd0), \
    .ch``c``_txdapicodereset(1'd0), \
    .ch``c``_txdetectrx(1'd0), \
    .ch``c``_txlatclk(1'd0), \
    .ch``c``_txphdlytstclk(1'd0), \
    .ch``c``_txdlyalignreq(1'd0), \
    .ch``c``_txelecidle(1'd0), \
    .ch``c``_txinhibit(1'd0), \
    .ch``c``_txmldchaindone(1'd0), \
    .ch``c``_txmldchainreq(1'd0), \
    .ch``c``_txoneszeros(1'd0), \
    .ch``c``_txpausedelayalign(1'd0), \
    .ch``c``_txpcsresetmask(1'd1), \
    .ch``c``_txphalignreq(1'd0), \
    .ch``c``_txphdlypd(1'd0), \
    .ch``c``_txphdlyreset(1'd0), \
    .ch``c``_txphsetinitreq(1'd0), \
    .ch``c``_txphshift180(1'd0), \
    .ch``c``_txpicodeovrden(1'd0), \
    .ch``c``_txpicodereset(1'd0), \
    .ch``c``_txpippmen(1'd0), \
    .ch``c``_txpisopd(1'd0), \
    .ch``c``_txpolarity(txpol_c[c]), \
    .ch``c``_txprbsforceerr(1'd0), \
    .ch``c``_txswing(1'd0), \
    .ch``c``_txsyncallin(1'd0), \
    .ch``c``_txctrl0(16'd0), \
    .ch``c``_txctrl1(16'd0), \
    .ch``c``_txdeemph(2'd0), \
    .ch``c``_txpd(2'd0), \
    .ch``c``_txresetmode(2'd0), \
    .ch``c``_txmstreset(txmstreset_c[c]), \
    .ch``c``_txmstdatapathreset(1'd0), \
    .ch``c``_txmstresetdone(txmstresetdone_c[c]), \
    .ch``c``_txmargin(3'd0), \
    .ch``c``_txpmaresetmask(3'd7), \
    .ch``c``_txprbssel(4'd0), \
    .ch``c``_txdiffctrl(diff_c[5*c +: 5]), \
    .ch``c``_txpippmstepsize(5'd0), \
    .ch``c``_txpostcursor(post_c[5*c +: 5]), \
    .ch``c``_txprecursor(pre_c[5*c +: 5]), \
    .ch``c``_txmaincursor(TX_MAINCURSOR), \
    .ch``c``_txctrl2(8'd0), \
    .ch``c``_txrate(8'd0), \
    .ch``c``_txprogdivresetdone(txprogdivresetdone_c[c]), \
    .ch``c``_txpmaresetdone(txpmaresetdone_c[c]), \
    .ch``c``_txdataextendrsvd(8'd0), \
    .ch``c``_txoutclk(txoutclk_c[c]), \
    .ch``c``_txusrclk(txusrclk_c[c]), \
    .ch``c``_rxdata(rxdata_c[128*c +: 128]), \
    .ch``c``_rxdatavalid(rxdatavalid_c[2*c +: 2]), \
    .ch``c``_rxheader(rxheader_c[6*c +: 6]), \
    .ch``c``_rxgearboxslip(rxslip_c[c]), \
    .ch``c``_rxlatclk(1'd0), \
    .ch``c``_gtrxreset(1'd0), \
    .ch``c``_rxprogdivreset(1'd0), \
    .ch``c``_rxuserrdy(rxuserrdy_c[c]), \
    .ch``c``_rxprogdivresetdone(rxprogdivresetdone_c[c]), \
    .ch``c``_rxpmaresetdone(rxpmaresetdone_c[c]), \
    .ch``c``_rxcdrhold(1'd0), \
    .ch``c``_rxcdrlock(rxcdrlock_c[c]), \
    .ch``c``_rxcdrovrden(1'd0), \
    .ch``c``_rxcdrreset(1'd0), \
    .ch``c``_rxchbondi(5'd0), \
    .ch``c``_rxdapicodeovrden(1'd0), \
    .ch``c``_rxdapicodereset(1'd0), \
    .ch``c``_rxdlyalignreq(1'd0), \
    .ch``c``_rxeqtraining(1'd0), \
    .ch``c``_rxheadervalid(rxheadervalid_c[2*c +: 2]), \
    .ch``c``_rxlpmen(lpm_c[c]), \
    .ch``c``_rxmldchaindone(1'd0), \
    .ch``c``_rxmldchainreq(1'd0), \
    .ch``c``_rxmlfinealignreq(1'd0), \
    .ch``c``_rxoobreset(1'd0), \
    .ch``c``_rxpcsresetmask(5'd31), \
    .ch``c``_rxpd(2'd0), \
    .ch``c``_rxphalignreq(1'd0), \
    .ch``c``_rxphalignresetmask(2'd3), \
    .ch``c``_rxphdlypd(1'd0), \
    .ch``c``_rxphdlyreset(1'd0), \
    .ch``c``_rxphsetinitreq(1'd0), \
    .ch``c``_rxphshift180(1'd0), \
    .ch``c``_rxpmaresetmask(7'd127), \
    .ch``c``_rxpolarity(rxpol_c[c]), \
    .ch``c``_rxprbscntreset(1'd0), \
    .ch``c``_rxprbssel(4'd0), \
    .ch``c``_rxrate(8'd0), \
    .ch``c``_rxresetmode(2'd0), \
    .ch``c``_rxmstreset(rxmstreset_c[c]), \
    .ch``c``_rxmstdatapathreset(rxdpreset_c[c]), \
    .ch``c``_rxmstresetdone(rxmstresetdone_c[c]), \
    .ch``c``_rxslide(1'd0), \
    .ch``c``_rxsyncallin(1'd0), \
    .ch``c``_rxtermination(1'd0), \
    .ch``c``_cdrbmcdrreq(1'd0), \
    .ch``c``_cdrfreqos(1'd0), \
    .ch``c``_cdrincpctrl(1'd0), \
    .ch``c``_cdrstepdir(1'd0), \
    .ch``c``_cdrstepsq(1'd0), \
    .ch``c``_cdrstepsx(1'd0), \
    .ch``c``_eyescanreset(1'd0), \
    .ch``c``_eyescantrigger(1'd0), \
    .ch``c``_cfokovrdfinish(1'd0), \
    .ch``c``_cfokovrdpulse(1'd0), \
    .ch``c``_cfokovrdstart(1'd0), \
    .ch``c``_rxoutclk(rxoutclk_c[c]), \
    .ch``c``_rxusrclk(rxusrclk_c[c]), \
    .ch``c``_clkrsvd0(1'd0), \
    .ch``c``_clkrsvd1(1'd0), \
    .ch``c``_dmonitorclk(1'd0), \
    .ch``c``_phyesmadaptsave(1'd0), \
    .ch``c``_iloresetmask(1'd1), \
    .ch``c``_loopback(lb_c[3*c +: 3]), \
    .ch``c``_dmonfiforeset(1'd0), \
    .ch``c``_pcsrsvdin(16'd0), \
    .ch``c``_gtrsvd(16'd0), \
    .ch``c``_tstin(20'd0), \
    .ch``c``_hsdppcsreset(1'd0), \
    .ch``c``_pcierstb(1'd1), \
    .ch``c``_iloreset(1'd0)


omac_versal_gty_quad u_gt (
    `OMAC_VGTQ_CH(0),
    `OMAC_VGTQ_CH(1),
    `OMAC_VGTQ_CH(2),
    `OMAC_VGTQ_CH(3),
    .resetdone_northin(2'd3),
    .resetdone_southin(2'd3),
    .txpinorthin(4'd0),
    .rxpinorthin(4'd0),
    .txpisouthin(4'd0),
    .rxpisouthin(4'd0),
    .pipenorthin(6'd0),
    .pipesouthin(6'd0),
    .GT_REFCLK0(refclk),
    .bgbypassb(1'd0),
    .bgmonitorenb(1'd0),
    .bgpdb(1'd0),
    .bgrcalovrdenb(1'd1),
    .bgrcalovrd(5'd0),
    .debugtraceready(1'd0),
    .debugtraceclk(1'd0),
    .rcalenb(1'd0),
    .trigackout0(1'd0),
    .trigin0(1'd0),
    .ubenable(1'd1),
    .ubiolmbrst(1'd0),
    .ubmbrst(1'd0),
    .ubintr(12'd0),
    .ubrxuart(1'd0),
    .ctrlrsvdin0(16'd0),
    .ctrlrsvdin1(14'd0),
    .gpi(16'd0),
    .refclk0_clktestsig(1'd0),
    .refclk1_clktestsig(1'd0),
    .altclk(1'd0),
    .hsclk0_lcpllclkrsvd0(1'd0),
    .hsclk0_lcpllclkrsvd1(1'd0),
    .hsclk0_rpllclkrsvd0(1'd0),
    .hsclk0_rpllclkrsvd1(1'd0),
    .hsclk1_lcpllclkrsvd0(1'd0),
    .hsclk1_lcpllclkrsvd1(1'd0),
    .hsclk1_rpllclkrsvd0(1'd0),
    .hsclk1_rpllclkrsvd1(1'd0),
    .hsclk0_lcpllrsvd0(8'd0),
    .hsclk0_lcpllrsvd1(8'd0),
    .hsclk0_rpllrsvd0(8'd0),
    .hsclk0_rpllrsvd1(8'd0),
    .hsclk1_lcpllrsvd0(8'd0),
    .hsclk1_lcpllrsvd1(8'd0),
    .hsclk1_rpllrsvd0(8'd0),
    .hsclk1_rpllrsvd1(8'd0),
    .apb3clk(freerun_clk),
    .apb3paddr(apb_paddr),
    .apb3penable(apb_penable),
    .apb3presetn(1'b1),
    .apb3prdata(apb_prdata),
    .apb3psel(apb_psel),
    .apb3pslverr(apb_pslverr),
    .apb3pready(apb_pready),
    .apb3pwdata(apb_pwdata),
    .apb3pwrite(apb_pwrite),
    .pcielinkreachtarget(1'd0),
    .refclk0_gtrefclkpd(1'd0),
    .hsclk0_lcpllsdmtoggle(1'd0),
    .hsclk0_rpllsdmtoggle(1'd0),
    .hsclk0_lcpllresetbypassmode(1'd0),
    .hsclk0_rpllresetbypassmode(1'd0),
    .hsclk0_lcpllpd(1'd0),
    .hsclk0_rpllpd(1'd0),
    .hsclk0_lcpllresetmask(2'd3),
    .hsclk0_rpllresetmask(2'd3),
    .hsclk0_lcpllfbdiv(8'd0),
    .hsclk0_rpllfbdiv(8'd0),
    .hsclk0_lcpllrefclksel(3'd1),
    .hsclk0_rpllrefclksel(3'd1),
    .hsclk0_rplllock(rplllock[0]),
    .hsclk0_lcpllreset(1'd0),
    .hsclk0_rpllreset(1'd0),
    .refclk1_gtrefclkpd(1'd0),
    .hsclk1_lcpllsdmtoggle(1'd0),
    .hsclk1_rpllsdmtoggle(1'd0),
    .hsclk1_lcpllresetbypassmode(1'd0),
    .hsclk1_rpllresetbypassmode(1'd0),
    .hsclk1_lcpllpd(1'd0),
    .hsclk1_rpllpd(1'd0),
    .hsclk1_lcpllresetmask(2'd3),
    .hsclk1_rpllresetmask(2'd3),
    .hsclk1_lcpllfbdiv(8'd0),
    .hsclk1_rpllfbdiv(8'd0),
    .hsclk1_lcpllrefclksel(3'd1),
    .hsclk1_rpllrefclksel(3'd1),
    .hsclk1_rplllock(rplllock[1]),
    .hsclk1_lcpllreset(1'd0),
    .hsclk1_rpllreset(1'd0),
    .hsclk0_lcpllsdmdata(26'd18729921),
    .hsclk1_lcpllsdmdata(26'd32216807),
    .hsclk0_rpllsdmdata(26'd4535360),
    .hsclk1_rpllsdmdata(26'd4520949),
    .rxmarginclk(1'd0),
    .rxmarginreqcmd(4'd0),
    .rxmarginreqlanenum(2'd0),
    .rxmarginreqpayld(8'd0),
    .rxmarginreqreq(1'd0),
    .rxmarginresack(1'd0),
    .gtpowergood(gtpowergood),
    .pcieltssm(6'd0),
    .rxp(rxp_c),
    .rxn(rxn_c),
    .txp(txp_c),
    .txn(txn_c)
);

`undef OMAC_VGTQ_CH

endmodule

`resetall
