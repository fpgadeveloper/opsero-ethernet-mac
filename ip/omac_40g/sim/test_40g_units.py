#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_40g_units.py - runs tb_40g_units (40GBASE-R alignment marker and BIP vectors
# from IEEE 802.3 tables 82-3 / 82-4, pcs_tx marker insertion and stall, lane
# receivers: AM lock, lane numbers, BIP errors, marker loss; CRC-32 identities of
# the 256-bit MAC).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(ROOT, 'sim'))
import simlib as S  # noqa: E402


def main():
    d = os.path.join(S.BUILD, 'omac_40g', 'units')
    srcs = S.ip_files('omac_40g') + [os.path.join(HERE, 'tb_40g_units.sv')]
    out, log = S.xsim(d, 'tb_40g_units', {}, srcs, incdirs=[os.path.join(ROOT, 'sim')])
    print('   ', out.replace('\n', '\n    '))
    ok = 'TB_PASS' in out
    print('40G UNITS TEST %s' % ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
