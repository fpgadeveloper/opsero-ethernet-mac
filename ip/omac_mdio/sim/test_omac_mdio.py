#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_omac_mdio.py - runs tb_omac_mdio (omac_mdio against three behavioural PHYs on
# one MDC/MDIO bus) in one configuration and prints its result lines.
# Usage: test_omac_mdio.py [base|fast] [--quick]
#   base: 100 MHz clk, DIV_INIT 19 (2.5 MHz MDC), push-pull MDIO, 2 synchroniser stages
#   fast: 250 MHz clk, DIV_INIT 49 (2.5 MHz MDC), OPEN_DRAIN = 1, 3 synchroniser stages
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(ROOT, 'sim'))
import simlib as S  # noqa: E402

CONFIGS = {
    'base': dict(CLK_HALF_PS=5000, OPEN_DRAIN=0, SYNC_STAGES=2, DIV_INIT=19),
    'fast': dict(CLK_HALF_PS=2000, OPEN_DRAIN=1, SYNC_STAGES=3, DIV_INIT=49),
}


def main():
    args = sys.argv[1:]
    quick = '--quick' in args
    names = [a for a in args if not a.startswith('--')] or ['base']
    ok_all = True
    for name in names:
        gen = dict(CONFIGS[name])
        gen['SOAK'] = 60 if quick else 300
        srcs = S.ip_files('omac_mdio') + [os.path.join(HERE, 'tb_mdio_phy.sv'), os.path.join(HERE, 'tb_omac_mdio.sv')]
        out, log = S.xsim(os.path.join(S.BUILD, 'omac_mdio', name), 'tb_omac_mdio', gen, srcs)
        os.makedirs(os.path.join(S.BUILD, 'omac_mdio', name), exist_ok=True)
        with open(os.path.join(S.BUILD, 'omac_mdio', name, 'xsim_run.log'), 'w') as f:
            f.write(log)
        print('   ', out.replace('\n', '\n    '))
        ok = 'TB_PASS' in out and 'TB_FAIL' not in out
        ok_all &= ok
        print('OMAC_MDIO %s TEST %s' % (name, 'PASS' if ok else 'FAIL'))
    return 0 if ok_all else 1


if __name__ == '__main__':
    sys.exit(main())
