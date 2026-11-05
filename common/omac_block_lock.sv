// SPDX-License-Identifier: MIT
//
// omac_block_lock - 64B/66B block synchronisation of one lane (IEEE 802.3
// clause 49.2.9, lock state diagram figure 49-14). Tests one sync header per
// valid block: 64 consecutive valid headers give block lock; without lock any
// invalid header, with lock 16 invalid headers within a 64-header window,
// slip the block boundary by one bit (`slip` pulse to the gearbox) and drop
// lock. After a slip, SLIP_WAIT cycles pass before headers are tested again
// (the gearbox needs time to apply the slip; AMD's gtwizard example design
// slips once per 256 cycles).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module omac_block_lock #(
    parameter int SLIP_WAIT = 256
) (
    input  wire logic       clk,
    input  wire logic       rst,
    input  wire logic       valid,
    input  wire logic [1:0] hdr,
    output logic            slip,
    output logic            lock
);

localparam int WW = $clog2(SLIP_WAIT + 1);

logic [6:0]  sh_cnt = '0;       // headers tested in this window (0..63)
logic [4:0]  sh_invld = '0;     // invalid headers in this window
logic [WW:0] wait_cnt = '0;

wire sh_valid = hdr[0] ^ hdr[1];

always_ff @(posedge clk) begin
    slip <= 1'b0;
    if (wait_cnt != '0) begin
        wait_cnt <= wait_cnt - 1'b1;
    end else if (valid) begin
        if (sh_valid) begin
            if (sh_cnt == 7'd63) begin
                if (sh_invld == '0) lock <= 1'b1;
                sh_cnt   <= '0;
                sh_invld <= '0;
            end else begin
                sh_cnt <= sh_cnt + 1'b1;
            end
        end else begin
            if (sh_invld == 5'd15 || !lock) begin
                lock     <= 1'b0;
                slip     <= 1'b1;
                wait_cnt <= (WW+1)'(SLIP_WAIT);
                sh_cnt   <= '0;
                sh_invld <= '0;
            end else if (sh_cnt == 7'd63) begin
                sh_cnt   <= '0;
                sh_invld <= '0;
            end else begin
                sh_cnt   <= sh_cnt + 1'b1;
                sh_invld <= sh_invld + 1'b1;
            end
        end
    end
    if (rst) begin
        lock     <= 1'b0;
        slip     <= 1'b0;
        sh_cnt   <= '0;
        sh_invld <= '0;
        wait_cnt <= '0;
    end
end

endmodule

`resetall
