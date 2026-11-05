// SPDX-License-Identifier: MIT
//
// tb_crc32 - omac_crc32 (BYTES wide) over frames read from a file, fed as words
// with a partial last word: writes "<fcs> <residue>" per frame (fcs = ~CRC of
// the frame; residue = CRC register after the frame + its FCS bytes).
// Plusargs: +in=<file> +out=<file>. Input lines: "<len> <hex bytes>".
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps
`default_nettype none

module tb_crc32 #(
    parameter int BYTES = 8
);

`include "tb_util.svh"

logic [31:0]          crc_in;
logic [8*BYTES-1:0]   data;
logic [$clog2(BYTES+1)-1:0] nb;
wire  [31:0]          crc_out;

omac_crc32 #(.BYTES(BYTES)) dut (.crc_in(crc_in), .data(data), .nbytes(nb), .crc_out(crc_out));

task automatic run_crc(ref byte unsigned q[$], output logic [31:0] c);
    int i;
    c = 32'hFFFF_FFFF;
    i = 0;
    while (i < q.size()) begin
        data = '0;
        nb = 0;
        for (int k = 0; k < BYTES && i < q.size(); k++) begin
            data[8*k +: 8] = q[i];
            i++;
            nb++;
        end
        // random garbage above nbytes must not matter
        for (int k = nb; k < BYTES; k++) data[8*k +: 8] = 8'($urandom);
        crc_in = c;
        #1;
        c = crc_out;
    end
endtask

initial begin
    string fin, fout, hex;
    integer fdi, fdo, len, r, n;
    byte unsigned q[$];
    logic [31:0] c, fcs, res;
    if (!$value$plusargs("in=%s", fin)) fin = "in.txt";
    if (!$value$plusargs("out=%s", fout)) fout = "out.txt";
    fdi = $fopen(fin, "r");
    fdo = $fopen(fout, "w");
    n = 0;
    while (!$feof(fdi)) begin
        r = $fscanf(fdi, "%d %s\n", len, hex);
        if (r != 2) break;
        tb_hex2bytes(hex, q);
        run_crc(q, c);
        fcs = ~c;
        for (int k = 0; k < 4; k++) q.push_back(fcs[8*k +: 8]);
        run_crc(q, res);
        $fdisplay(fdo, "%08x %08x", fcs, res);
        n++;
    end
    $fclose(fdo);
    $display("TB_DONE frames=%0d", n);
    $finish;
end

endmodule
