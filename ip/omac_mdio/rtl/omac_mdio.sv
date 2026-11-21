// SPDX-License-Identifier: MIT
//
// omac_mdio - MDIO master (station management entity) with an AXI4-Lite slave:
// IEEE 802.3 clause 22 frames (read, write) and clause 45 frames (address, write,
// read, post-read-increment-address), for PHYs on a shared MDC/MDIO bus.
//
// * MDC = clk / (2 (DIV + 1)), DIV programmable (CFG[7:0], reset DIV_INIT); held low
//   between frames or free-running (CFG.MDC_FREE).
// * Frame = PRE_LEN preamble ones (CFG[13:8], reset PRE_INIT, 0 = preamble
//   suppressed) + 32 frame bits + one idle bit (MDIO released).
// * The master changes MDIO with the falling edge of MDC (setup and hold at the
//   PHY = half an MDC period each) and samples MDIO at the rising edge of MDC at its
//   own pins (the PHY drives read data after the rising edge, 0-300 ns in clause 22).
// * Read-type frames release MDIO from the first turnaround bit; the second
//   turnaround bit must be 0 (driven by the PHY), else TA_ERR (no PHY answered).
// * One-command interface: CMD (+ WDATA) starts a command, STATUS.BUSY / DONE, RDATA,
//   optional level interrupt. CMD.ADDR_FIRST runs a clause 45 address frame and the
//   data frame back to back as one command.
// * Hold-off: while `hold` (input, synchronised) or CFG.HOLD is 1 no command starts
//   (STATUS.HELD); a command that has started runs to its end.
// * ABORT cancels a waiting command without bus activity or stops a running frame at
//   once; the next frame is then preceded by 64 MDC cycles with MDIO released, so
//   every PHY has finished the cut frame and sees a full preamble again.
// * Bit-bang mode (BITBANG.BB_EN): MDC and MDIO follow register bits, for debugging.
// * mdio_o / mdio_t / mdio_i drive an IOBUF (T = 1: released). OPEN_DRAIN = 1 never
//   drives a 1 (a released bus is pulled up), for open-drain buses.
// Register map (byte addresses, 32-bit registers, every access answers OKAY):
//   0x000 ID       0x4D44494F ("MDIO")
//   0x004 VERSION  0x00000100
//   0x008 CFG      [7:0] DIV, [13:8] PRE_LEN, [16] MDC_FREE, [17] IRQ_EN, [18] HOLD
//   0x00C CMD      [1:0] OP, [2] C45, [3] ADDR_FIRST, [12:8] PHYAD/PRTAD,
//                  [20:16] REGAD/DEVAD; a write starts the command
//   0x010 WDATA    [15:0] write data / address, [31:16] address of the ADDR_FIRST frame
//   0x014 RDATA    [15:0] read data, [16] RD_VALID
//   0x018 STATUS   [0] BUSY, [1] DONE (w1c), [2] RD_VALID, [3] TA_ERR, [4] BUS_ERR,
//                  [5] ABORTED, [6] CMD_IGN (w1c), [8] HELD, [9] HOLD, [10] MDIO_IN
//   0x01C CTRL     [0] ABORT (write 1)
//   0x020 BITBANG  [0] MDC, [1] MDIO_O, [2] MDIO_OE, [31] BB_EN; read [8] MDIO_IN
// Documentation: docs/omac_mdio.md.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_mdio #(
    parameter int DIV_INIT    = 19,     // MDC half period - 1 after reset (2.5 MHz at 100 MHz)
    parameter int PRE_INIT    = 32,     // preamble length after reset (0-63)
    parameter bit OPEN_DRAIN  = 1'b0,   // 1: never drive MDIO high (open-drain bus)
    parameter int SYNC_STAGES = 2       // synchroniser flops on mdio_i and hold (2-4)
) (
    input  wire logic        clk,
    input  wire logic        rst,

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
    input  wire logic        s_axil_rready,

    output logic             irq,
    input  wire logic        hold,

    output logic             mdc,
    input  wire logic        mdio_i,
    output logic             mdio_o,
    output logic             mdio_t
);

localparam logic [31:0] ID      = 32'h4D44_494F;
localparam logic [31:0] VERSION = 32'h0000_0100;
localparam int          SPL     = SYNC_STAGES + 1;   // sample pipeline length

initial begin
    if (SYNC_STAGES < 2 || SYNC_STAGES > 4) $fatal(1, "omac_mdio: SYNC_STAGES must be 2-4");
    if (DIV_INIT < 0 || DIV_INIT > 255) $fatal(1, "omac_mdio: DIV_INIT must be 0-255");
    if (PRE_INIT < 0 || PRE_INIT > 63) $fatal(1, "omac_mdio: PRE_INIT must be 0-63");
end

// ---------------------------------------------------------------- synchronisers
logic mdio_s, hold_s;
omac_sync_bit #(.STAGES(SYNC_STAGES), .INIT(1'b1)) u_sync_mdio (.clk(clk), .din(mdio_i), .dout(mdio_s));
omac_sync_bit #(.STAGES(SYNC_STAGES), .INIT(1'b0)) u_sync_hold (.clk(clk), .din(hold), .dout(hold_s));

// ---------------------------------------------------------------- registers
logic [7:0]  cfg_div;
logic [5:0]  cfg_pre;
logic        cfg_free, cfg_irq_en, cfg_hold;
logic [1:0]  cmd_op;
logic        cmd_c45, cmd_a1st;
logic [4:0]  cmd_pa, cmd_ra;
logic [31:0] wdata;
logic [15:0] rdata;
logic        st_busy, st_done, st_rdv, st_ta_err, st_bus_err, st_aborted, st_cmd_ign;
logic        bb_en, bb_mdc, bb_o, bb_oe;

// ---------------------------------------------------------------- engine
typedef enum logic [2:0] {S_IDLE, S_WAIT, S_RESYNC, S_PRE, S_FRAME, S_END} state_t;
state_t      state;
logic [6:0]  bitcnt;
logic        resync;         // next frame starts with 64 released MDC cycles
logic        second;         // the data frame of an ADDR_FIRST command
logic        two;            // the running command has an address frame first
logic        cur_rd;         // the running command reads
logic [7:0]  div_l;          // DIV and PRE_LEN latched per command
logic [5:0]  pre_l;
logic [31:0] frame;          // the 32 frame bits of the current frame, first bit = [31]
logic        eng_mdc, eng_o, eng_t;
logic [7:0]  div_cnt;
logic [15:0] rx_sr;
logic        ta_bit;
// sample pipeline: one entry per rising edge of MDC
logic [SPL-1:0] sp_v, sp_drv, sp_exp, sp_ta, sp_dat;

wire  eff_hold     = hold_s | cfg_hold;
wire  frame_active = (state == S_RESYNC) || (state == S_PRE) || (state == S_FRAME);
wire  [7:0] div_use = frame_active ? div_l : cfg_div;
wire  gen_run      = !bb_en && (cfg_free || frame_active || eng_mdc);
wire  tick         = (div_cnt >= div_use);
wire  fall_now     = gen_run && tick && eng_mdc;
wire  rise_now     = gen_run && tick && !eng_mdc;
wire  start_ok     = (state == S_WAIT) && (second || !eff_hold) && (cfg_free ? fall_now : !eng_mdc);
wire  bnd          = start_ok || (frame_active && fall_now);   // a new bit starts in this cycle
wire  frame_rd     = cur_rd && !(two && !second);               // the current frame reads

// what the next bit is (evaluated at a bit boundary)
state_t     nx_state;
logic [6:0] nx_cnt;
logic       nx_o, nx_t;
always_comb begin
    logic go_pre, go_frame;
    nx_state = state;
    nx_cnt   = bitcnt + 7'd1;
    go_pre   = 1'b0;
    go_frame = 1'b0;
    case (state)
        S_WAIT: begin
            if (resync) begin
                nx_state = S_RESYNC;
                nx_cnt   = '0;
            end else if (pre_l != 0) go_pre = 1'b1;
            else go_frame = 1'b1;
        end
        S_RESYNC: if (bitcnt == 7'd63) begin
            if (pre_l != 0) go_pre = 1'b1; else go_frame = 1'b1;
        end
        S_PRE:   if (bitcnt == 7'(pre_l) - 7'd1) go_frame = 1'b1;
        S_FRAME: if (bitcnt == 7'd32) nx_state = S_END;
        default: ;
    endcase
    if (go_pre) begin
        nx_state = S_PRE;
        nx_cnt   = '0;
    end
    if (go_frame) begin
        nx_state = S_FRAME;
        nx_cnt   = '0;
    end
    nx_t = 1'b1;
    nx_o = 1'b1;
    if (nx_state == S_PRE) nx_t = 1'b0;
    if (nx_state == S_FRAME && nx_cnt < 7'd32 && !(frame_rd && nx_cnt >= 7'd14)) begin
        nx_t = 1'b0;
        nx_o = frame[5'd31 - nx_cnt[4:0]];
    end
end

function automatic logic [31:0] frame_word(input logic c45, input logic [1:0] op,
                                           input logic [4:0] pa, input logic [4:0] ra,
                                           input logic [15:0] data);
    return {1'b0, !c45, op, pa, ra, 2'b10, data};
endfunction

// AXI write decode
wire        wr_go  = s_axil_awvalid && s_axil_wvalid && !s_axil_awready && !s_axil_bvalid;
wire [9:0]  wr_w   = s_axil_awaddr[11:2];
wire        wr_cfg = wr_go && wr_w == 10'h002;
wire        wr_cmd = wr_go && wr_w == 10'h003;
wire        wr_wd  = wr_go && wr_w == 10'h004;
wire        wr_st  = wr_go && wr_w == 10'h006;
wire        wr_ctl = wr_go && wr_w == 10'h007;
wire        wr_bb  = wr_go && wr_w == 10'h008;
wire        do_abort = (wr_ctl && s_axil_wstrb[0] && s_axil_wdata[0]) ||
                       (wr_bb && s_axil_wstrb[3] && s_axil_wdata[31] && !bb_en);
wire        accept = wr_cmd && !st_busy && !bb_en;

always_ff @(posedge clk) begin
    // write channel: address and data together
    s_axil_awready <= 1'b0;
    s_axil_wready  <= 1'b0;
    if (s_axil_bvalid && s_axil_bready) s_axil_bvalid <= 1'b0;
    if (wr_go) begin
        s_axil_awready <= 1'b1;
        s_axil_wready  <= 1'b1;
        s_axil_bvalid  <= 1'b1;
    end
    if (wr_cfg) begin
        if (s_axil_wstrb[0]) cfg_div <= s_axil_wdata[7:0];
        if (s_axil_wstrb[1]) cfg_pre <= s_axil_wdata[13:8];
        if (s_axil_wstrb[2]) {cfg_hold, cfg_irq_en, cfg_free} <= s_axil_wdata[18:16];
    end
    if (wr_wd) begin
        for (int i = 0; i < 4; i++) if (s_axil_wstrb[i]) wdata[8*i +: 8] <= s_axil_wdata[8*i +: 8];
    end
    if (wr_bb) begin
        if (s_axil_wstrb[0]) {bb_oe, bb_o, bb_mdc} <= s_axil_wdata[2:0];
        if (s_axil_wstrb[3]) bb_en <= s_axil_wdata[31];
    end
    if (wr_st && s_axil_wstrb[0]) begin
        if (s_axil_wdata[1]) st_done    <= 1'b0;
        if (s_axil_wdata[6]) st_cmd_ign <= 1'b0;
    end
    if (wr_cmd && !accept) st_cmd_ign <= 1'b1;

    // MDC generator
    if (!gen_run) begin
        div_cnt <= '0;
        eng_mdc <= 1'b0;
    end else if (tick) begin
        div_cnt <= '0;
        eng_mdc <= !eng_mdc;
    end else begin
        div_cnt <= div_cnt + 8'd1;
    end

    // sample pipeline (entry at the rising edge, used SYNC_STAGES + 1 cycles later, when
    // mdio_s shows the pin as it was at the clock edge where MDC rose at the pin)
    sp_v   <= {sp_v[SPL-2:0], 1'b0};
    sp_drv <= {sp_drv[SPL-2:0], !eng_t};
    sp_exp <= {sp_exp[SPL-2:0], eng_o};
    sp_ta  <= {sp_ta[SPL-2:0], 1'b0};
    sp_dat <= {sp_dat[SPL-2:0], 1'b0};
    if (rise_now && (state == S_PRE || state == S_FRAME)) begin
        sp_v[0]   <= 1'b1;
        sp_ta[0]  <= state == S_FRAME && frame_rd && bitcnt == 7'd15;
        sp_dat[0] <= state == S_FRAME && frame_rd && bitcnt >= 7'd16 && bitcnt < 7'd32;
    end
    if (sp_v[SPL-1]) begin
        if (sp_drv[SPL-1] && mdio_s != sp_exp[SPL-1]) st_bus_err <= 1'b1;
        if (sp_ta[SPL-1]) ta_bit <= mdio_s;
        if (sp_dat[SPL-1]) rx_sr <= {rx_sr[14:0], mdio_s};
    end

    // command accept
    if (accept) begin
        cmd_op   <= s_axil_wdata[1:0];
        cmd_c45  <= s_axil_wdata[2];
        cmd_a1st <= s_axil_wdata[3];
        cmd_pa   <= s_axil_wdata[12:8];
        cmd_ra   <= s_axil_wdata[20:16];
        two      <= s_axil_wdata[2] && s_axil_wdata[3] && s_axil_wdata[1:0] != 2'b00;
        cur_rd   <= s_axil_wdata[2] ? s_axil_wdata[1] : (s_axil_wdata[1:0] == 2'b10);
        second   <= 1'b0;
        div_l    <= cfg_div;
        pre_l    <= cfg_pre;
        if (s_axil_wdata[2] && s_axil_wdata[3] && s_axil_wdata[1:0] != 2'b00)
            frame <= frame_word(1'b1, 2'b00, s_axil_wdata[12:8], s_axil_wdata[20:16], wdata[31:16]);
        else
            frame <= frame_word(s_axil_wdata[2], s_axil_wdata[1:0], s_axil_wdata[12:8],
                                s_axil_wdata[20:16], wdata[15:0]);
        st_busy    <= 1'b1;
        st_done    <= 1'b0;
        st_rdv     <= 1'b0;
        st_ta_err  <= 1'b0;
        st_bus_err <= 1'b0;
        st_aborted <= 1'b0;
        ta_bit     <= 1'b1;
        state      <= S_WAIT;
    end

    // bits
    if (bnd) begin
        state  <= nx_state;
        bitcnt <= nx_cnt;
        eng_o  <= nx_o;
        eng_t  <= nx_t;
        if (nx_state != S_RESYNC) resync <= 1'b0;
    end

    // end of a frame: wait for the last samples, then the next frame or done
    if (state == S_END && sp_v == '0) begin
        if (two && !second) begin
            second <= 1'b1;
            frame  <= frame_word(1'b1, cmd_op, cmd_pa, cmd_ra, wdata[15:0]);
            ta_bit <= 1'b1;
            state  <= S_WAIT;
        end else begin
            state   <= S_IDLE;
            st_busy <= 1'b0;
            st_done <= 1'b1;
            if (cur_rd) begin
                rdata     <= rx_sr;
                st_rdv    <= !ta_bit;
                st_ta_err <= ta_bit;
            end
        end
    end

    // abort (also when bit-bang mode is switched on)
    if (do_abort && st_busy) begin
        if (frame_active || state == S_END) resync <= 1'b1;
        state      <= S_IDLE;
        eng_o      <= 1'b1;
        eng_t      <= 1'b1;
        sp_v       <= '0;
        st_busy    <= 1'b0;
        st_done    <= 1'b1;
        st_aborted <= 1'b1;
    end

    irq <= cfg_irq_en && st_done;

    if (rst) begin
        s_axil_awready <= 1'b0;
        s_axil_wready  <= 1'b0;
        s_axil_bvalid  <= 1'b0;
        cfg_div    <= 8'(DIV_INIT);
        cfg_pre    <= 6'(PRE_INIT);
        cfg_free   <= 1'b0;
        cfg_irq_en <= 1'b0;
        cfg_hold   <= 1'b0;
        cmd_op     <= '0;
        cmd_c45    <= 1'b0;
        cmd_a1st   <= 1'b0;
        cmd_pa     <= '0;
        cmd_ra     <= '0;
        wdata      <= '0;
        rdata      <= '0;
        st_busy    <= 1'b0;
        st_done    <= 1'b0;
        st_rdv     <= 1'b0;
        st_ta_err  <= 1'b0;
        st_bus_err <= 1'b0;
        st_aborted <= 1'b0;
        st_cmd_ign <= 1'b0;
        bb_en      <= 1'b0;
        bb_mdc     <= 1'b0;
        bb_o       <= 1'b1;
        bb_oe      <= 1'b0;
        state      <= S_IDLE;
        bitcnt     <= '0;
        resync     <= 1'b0;
        second     <= 1'b0;
        two        <= 1'b0;
        cur_rd     <= 1'b0;
        div_l      <= 8'(DIV_INIT);
        pre_l      <= 6'(PRE_INIT);
        frame      <= '0;
        eng_mdc    <= 1'b0;
        eng_o      <= 1'b1;
        eng_t      <= 1'b1;
        div_cnt    <= '0;
        rx_sr      <= '0;
        ta_bit     <= 1'b1;
        sp_v       <= '0;
        irq        <= 1'b0;
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
            10'h000: s_axil_rdata <= ID;
            10'h001: s_axil_rdata <= VERSION;
            10'h002: s_axil_rdata <= {13'd0, cfg_hold, cfg_irq_en, cfg_free, 2'd0, cfg_pre, cfg_div};
            10'h003: s_axil_rdata <= {11'd0, cmd_ra, 3'd0, cmd_pa, 4'd0, cmd_a1st, cmd_c45, cmd_op};
            10'h004: s_axil_rdata <= wdata;
            10'h005: s_axil_rdata <= {15'd0, st_rdv, rdata};
            10'h006: s_axil_rdata <= {21'd0, mdio_s, eff_hold, (state == S_WAIT) && !second && eff_hold,
                                      1'b0, st_cmd_ign, st_aborted, st_bus_err, st_ta_err, st_rdv,
                                      st_done, st_busy};
            10'h008: s_axil_rdata <= {bb_en, 22'd0, mdio_s, 5'd0, bb_oe, bb_o, bb_mdc};
            default: s_axil_rdata <= '0;
        endcase
    end
    if (rst) begin
        s_axil_arready <= 1'b0;
        s_axil_rvalid  <= 1'b0;
    end
end
assign s_axil_rresp = 2'b00;

// outputs (registered; bit-bang mux; open-drain option)
always_ff @(posedge clk) begin
    logic o, t;
    o = bb_en ? bb_o : eng_o;
    t = bb_en ? !bb_oe : eng_t;
    mdc    <= bb_en ? bb_mdc : eng_mdc;
    mdio_o <= OPEN_DRAIN ? 1'b0 : o;
    mdio_t <= OPEN_DRAIN ? (t | o) : t;
    if (rst) begin
        mdc    <= 1'b0;
        mdio_o <= OPEN_DRAIN ? 1'b0 : 1'b1;
        mdio_t <= 1'b1;
    end
end

endmodule

`resetall
