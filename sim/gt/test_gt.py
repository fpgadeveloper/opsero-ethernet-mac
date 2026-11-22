#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_gt.py <gty|gth|versal> [nframes] - run sim/gt/run_gt_sim.tcl (transceiver-level loop of the
# quad wrapper with the vendor's GT simulation models) in one Vivado batch process and check
# its "GT_SIM <fam> PASS" line. Build products: sim/build/gt_<fam> (or $SIM_BUILD/gt_<fam>).
# Part of the regression only with sim/run_tests.py --gt (slow).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.dirname(HERE)
sys.path.insert(0, SIM)
import simlib  # noqa: E402


def main():
    fam = sys.argv[1] if len(sys.argv) > 1 else 'gty'
    nframes = sys.argv[2] if len(sys.argv) > 2 else '12'
    out = os.path.join(simlib.BUILD, 'gt_' + fam)
    env = simlib._tool_env()
    cmd = ['vivado', '-mode', 'batch', '-nojournal', '-nolog', '-notrace',
           '-source', os.path.join(HERE, 'run_gt_sim.tcl'), '-tclargs', fam, out, nframes]
    os.makedirs(simlib.BUILD, exist_ok=True)
    r = subprocess.run(cmd, cwd=simlib.BUILD, env=env, capture_output=True, text=True)
    lines = [l for l in r.stdout.splitlines() if l.startswith(('TB_', 'GT_SIM')) or 'ERROR' in l]
    print('\n'.join(lines))
    return 0 if any(l.startswith('GT_SIM %s PASS' % fam) for l in lines) else 1


if __name__ == '__main__':
    sys.exit(main())
