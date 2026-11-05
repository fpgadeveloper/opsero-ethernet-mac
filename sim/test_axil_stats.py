#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_axil_stats.py - runs tb_axil_stats (optional AXI-Lite statistics block).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import simlib as S  # noqa: E402


def main():
    out, log = S.xsim(os.path.join(S.BUILD, 'axil_stats'), 'tb_axil_stats', {},
                      S.common('omac_axil_stats.sv') + [os.path.join(HERE, 'tb_axil_stats.sv')])
    print('   ', out.replace('\n', '\n    '))
    ok = 'TB_PASS' in out
    print('AXIL STATS TEST %s' % ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
