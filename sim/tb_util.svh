// SPDX-License-Identifier: MIT
//
// tb_util.svh - testbench helpers: hex string <-> byte queue.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

function automatic int tb_hexval(byte ch);
    if (ch >= "0" && ch <= "9") return ch - "0";
    if (ch >= "a" && ch <= "f") return ch - "a" + 10;
    if (ch >= "A" && ch <= "F") return ch - "A" + 10;
    return 0;
endfunction

task automatic tb_hex2bytes(input string s, ref byte unsigned q[$]);
    q.delete();
    for (int i = 0; i + 1 < s.len(); i += 2) q.push_back(8'(tb_hexval(s[i]) * 16 + tb_hexval(s[i+1])));
endtask

function automatic string tb_bytes2hex(ref byte unsigned q[$]);
    string s;
    s = "";
    foreach (q[i]) s = {s, $sformatf("%02x", q[i])};
    return s;
endfunction
