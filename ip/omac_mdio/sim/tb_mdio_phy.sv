// SPDX-License-Identifier: MIT
//
// tb_mdio_phy - behavioural MDIO slave (PHY management interface) for the omac_mdio
// testbench, written from IEEE 802.3 clause 22.2.4.5 and clause 45.3, independent of
// the RTL. One PHY / port address (ADDR) on a shared bus:
// * frame start = a 0 after at least MIN_PRE consecutive ones sampled at rising MDC
//   edges (32 = full preamble required; 1 = accepts preamble suppression);
// * clause 22 (ST 01): write (OP 01), read (OP 10) of 32 registers (C22 = 1);
// * clause 45 (ST 00): address (OP 00), write (01), read (11), post-read-increment-
//   address (10) for MMDs 0-31, one address register per MMD (C45 = 1);
// * frames for another address, or of a clause it does not support, are skipped
//   (it stays quiet for the rest of the frame);
// * write frames: the turnaround must be 1, 0 (else ta_err);
// * read frames: the PHY drives 0 in the second turnaround bit and the 16 data bits,
//   each `tout` after the rising MDC edge that ends the previous bit (tout random per
//   frame in [tout_min, tout_max]), and releases MDIO `tout` after the rising edge of
//   the last data bit; board delay 5 ns on its driver.
// Register contents: clause 22 register r = init22(r), clause 45 (dev, a) = init45(dev, a)
// until written.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_mdio_phy #(
    parameter int ADDR    = 1,
    parameter bit C22     = 1'b1,
    parameter bit C45     = 1'b1,
    parameter int MIN_PRE = 32
) (
    input wire mdc,
    inout tri1 mdio
);

logic oe = 1'b0, o = 1'b1;
assign #5 mdio = oe ? o : 1'bz;
wire oe_d;
assign #5 oe_d = oe;

real tout_min = 1.0, tout_max = 300.0, tout_ns = 10.0;

logic [15:0] r22 [32];
logic [15:0] m45 [int];
logic [15:0] areg [32];

int n_frames = 0, n_rd22 = 0, n_wr22 = 0, n_addr45 = 0, n_wr45 = 0, n_rd45 = 0, n_pria45 = 0;
int ta_err = 0, last_pre = 0, n_skipped = 0;

function automatic logic [15:0] init22(int a);
    return 16'h2200 ^ 16'(ADDR << 8) ^ 16'(a * 16'h0101);
endfunction

function automatic logic [15:0] init45(int dev, int a);
    return 16'((a * 40503) ^ (dev << 11) ^ (ADDR << 6) ^ 16'h5A5A);
endfunction

function automatic logic [15:0] rd45(int dev, int a);
    int k = dev * 65536 + a;
    return m45.exists(k) ? m45[k] : init45(dev, a);
endfunction

initial for (int i = 0; i < 32; i++) begin
    r22[i]  = init22(i);
    areg[i] = '0;
end

initial begin
    int ones;
    logic [12:0] hdr;
    logic [15:0] data;
    logic [1:0]  op, ta;
    logic [4:0]  pa, ra;
    bit c45, rd, mine;
    ones = 0;
    forever begin
        @(posedge mdc);
        if (mdio !== 1'b0) begin
            ones++;
            continue;
        end
        if (ones < MIN_PRE) begin
            ones = 0;
            continue;
        end
        // start: the first ST bit (0) after the preamble / idle
        last_pre = ones;
        ones = 0;
        for (int i = 0; i < 13; i++) begin
            @(posedge mdc);
            hdr = {hdr[11:0], (mdio !== 1'b0)};
        end
        c45  = !hdr[12];
        op   = hdr[11:10];
        pa   = hdr[9:5];
        ra   = hdr[4:0];
        rd   = c45 ? op[1] : (op == 2'b10);
        mine = (pa == ADDR) && (c45 ? C45 : (C22 && (op == 2'b01 || op == 2'b10)));
        if (!mine) begin
            n_skipped++;
            repeat (18) @(posedge mdc);
            continue;
        end
        n_frames++;
        tout_ns = tout_min + (tout_max - tout_min) * ($urandom_range(1000) / 1000.0);
        if (rd) begin
            data = c45 ? rd45(ra, areg[ra]) : r22[ra];
            @(posedge mdc);                       // rising edge of the first turnaround bit
            #(tout_ns);
            o  = 1'b0;
            oe = 1'b1;
            for (int i = 0; i < 16; i++) begin
                @(posedge mdc);                   // rising edge of the previous bit
                #(tout_ns);
                o = data[15 - i];
            end
            @(posedge mdc);                       // rising edge of the last data bit
            #(tout_ns);
            oe = 1'b0;
            o  = 1'b1;
            if (!c45) n_rd22++;
            else if (op == 2'b11) n_rd45++;
            else begin
                n_pria45++;
                areg[ra] = areg[ra] + 16'd1;
            end
        end else begin
            @(posedge mdc); ta[1] = (mdio !== 1'b0);
            @(posedge mdc); ta[0] = (mdio !== 1'b0);
            if (ta != 2'b10) begin
                ta_err++;
                $display("TB_ERR phy%0d: write turnaround %b at %t", ADDR, ta, $realtime);
            end
            for (int i = 0; i < 16; i++) begin
                @(posedge mdc);
                data = {data[14:0], (mdio !== 1'b0)};
            end
            if (!c45) begin
                r22[ra] = data;
                n_wr22++;
            end else if (op == 2'b00) begin
                areg[ra] = data;
                n_addr45++;
            end else begin
                m45[ra * 65536 + areg[ra]] = data;
                n_wr45++;
            end
        end
    end
end

endmodule
