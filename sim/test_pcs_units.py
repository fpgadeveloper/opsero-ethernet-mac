#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_pcs_units.py - runs tb_pcs_units (64B/66B interop vectors from IEEE 802.3
# figure 49-7, encode/decode round trip, scrambler vs a bit-serial model,
# descrambler self-synchronisation).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import simlib as S  # noqa: E402


def main():
    d = os.path.join(S.BUILD, 'pcs_units')
    out, log = S.xsim(d, 'tb_pcs_units', {}, S.common('omac_scrambler.sv', 'omac_descrambler.sv') +
                      [os.path.join(HERE, 'tb_pcs_units.sv')])
    print('   ', out.replace('\n', '\n    '))
    ok = 'TB_PASS' in out
    print('PCS UNITS TEST %s' % ('PASS' if ok else 'FAIL'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
