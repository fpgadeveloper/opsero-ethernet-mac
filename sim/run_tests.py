#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# run_tests.py - the opsero-ethernet-mac simulation regression (Vivado xsim +
# Python models). Runs every test, prints one PASS/FAIL line per test and a
# summary, exits non-zero if any test fails. --quick uses smaller workloads;
# -k <substring> selects tests. Build products: sim/build (git-ignored).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
T10 = os.path.join(ROOT, 'ip', 'omac_10g', 'sim', 'test_omac_10g.py')
T40 = os.path.join(ROOT, 'ip', 'omac_40g', 'sim', 'test_omac_40g.py')
U40 = os.path.join(ROOT, 'ip', 'omac_40g', 'sim', 'test_40g_units.py')

# name: (script, full arguments, quick arguments, what it covers)
TESTS = [
    ('bd_wrapper', os.path.join(ROOT, 'scripts', 'gen_bd_wrapper.py'), ['--check'], ['--check'],
     'ip/<ip>/rtl/<ip>_bd.v are up to date with omac_10g.sv / omac_40g.sv'),
    ('ref_model', 'omac_ref.py', [], [], 'Python reference model selftest (hand vectors, CRC check value)'),
    ('crc32', 'test_crc32.py', ['400', '1'], ['100', '1'],
     'omac_crc32 at 8 and 32 bytes vs zlib.crc32, check value, residue'),
    ('pcs_units', 'test_pcs_units.py', [], [],
     '64B/66B interop vectors (fig. 49-7), encode/decode round trip, scrambler vs bit-serial model'),
    ('axil_stats', 'test_axil_stats.py', [], [], 'optional AXI-Lite statistics block'),
    ('10g_frames', T10, ['frames', '--seed', '1'], ['frames', '--seed', '1', '--quick'],
     'omac_10g pair: frames 1-9000 B both ways, lock from random phase, Python decode of the wire, DIC'),
    ('10g_frames_s2', T10, ['frames', '--seed', '2'], ['frames', '--seed', '2', '--quick'],
     'the same, another seed (other phases, lengths)'),
    ('10g_errors', T10, ['errors'], ['errors', '--quick'], 'TX abort / underflow, line bit flips -> FCS errors'),
    ('10g_runt', T10, ['runt'], ['runt', '--quick'], 'runts (no TX pad) and oversize (MAX_FRAME 1518)'),
    ('10g_pause10', T10, ['pause10'], ['pause10'], 'PAUSE at 10G: XOFF timing, XON, refresh, honour, frame contents'),
    ('10g_pause25', T10, ['pause25'], ['pause25'], 'PAUSE at 25G (SPEED 25, 2.56 ns)'),
    ('10g_frames25', T10, ['frames25', '--seed', '3'], ['frames25', '--seed', '3'], 'frames at SPEED 25'),
    ('10g_fault', T10, ['fault'], ['fault'], 'Local Fault -> Remote Fault, Remote Fault -> idles, recovery'),
    ('10g_hiber', T10, ['hiber'], ['hiber'], 'BER monitor: no hi_ber at low rate, hi_ber, clear, relock'),
    ('10g_watchdog', T10, ['watchdog'], ['watchdog'], 'no lock -> gt_rx_reset_req'),
    ('10g_ts', T10, ['ts'], ['ts', '--quick'], 'timestamp hooks (TS_EN): TX ts = /S/ block on the wire (Python decode), '
     'RX ts = TX ts + channel latency, lane 4, PAUSE, drops, aborts, line errors, min-gap frames'),
    ('10g_ts25', T10, ['ts25'], ['ts25', '--quick'], 'timestamp hooks at SPEED 25'),
    ('40g_units', U40, [], [], '40GBASE-R marker / BIP vectors (tables 82-3/82-4), marker insertion + stall, '
     'lane AM lock + BIP, 256-bit CRC identities'),
    ('40g_frames', T40, ['frames', '--seed', '1'], ['frames', '--seed', '1', '--quick'],
     'omac_40g pair: 600 frames each way, random lane order / skew / phase, Python MLD decode of the four lanes'),
    ('40g_frames_s2', T40, ['frames', '--seed', '2'], ['frames', '--seed', '2', '--quick'],
     'the same, another seed'),
    ('40g_perms', T40, ['perms'], ['perms', '--quick'], 'all 24 lane orders with random skew: relock + frames'),
    ('40g_skew', T40, ['skew'], ['skew'], 'skew beyond DESKEW_MAX: no alignment; within: relock'),
    ('40g_lanefail', T40, ['lanefail'], ['lanefail'], 'one lane dies: local / remote fault, recovery'),
    ('40g_hiber', T40, ['hiber'], ['hiber'], 'BER monitor over four lanes (97 in 1.25 ms)'),
    ('40g_errors', T40, ['errors'], ['errors', '--quick'], 'aborts / underflows; line bit flips -> FCS + BIP errors'),
    ('40g_overflow', T40, ['overflow'], ['overflow'], 'RX reader stalled: frames cut / dropped, never corrupted'),
    ('40g_runt', T40, ['runt'], ['runt', '--quick'], 'runts (no TX pad) and oversize (MAX_FRAME 1518)'),
    ('40g_pause', T40, ['pause'], ['pause'], 'PAUSE at 40G: 100 quanta = 200 cycles, XON, refresh, honour, contents'),
    ('40g_fault', T40, ['fault'], ['fault'], 'Local Fault -> Remote Fault, Remote Fault -> idles, recovery'),
    ('40g_rate', T40, ['rate'], ['rate', '--quick'], '10,000 minimum + 1,000 maximum frames back to back: line rate'),
    ('40g_watchdog', T40, ['watchdog'], ['watchdog'], 'no alignment -> gt_rx_reset_req'),
]


def main():
    args = sys.argv[1:]
    quick = '--quick' in args
    sel = args[args.index('-k') + 1] if '-k' in args else None
    results = []
    t_all = time.time()
    for name, script, full, qargs, what in TESTS:
        if sel and sel not in name:
            continue
        path = script if os.path.isabs(script) else os.path.join(HERE, script)
        cmd = [sys.executable, '-I', path] + (qargs if quick else full)
        t0 = time.time()
        r = subprocess.run(cmd, capture_output=True, text=True)
        dt = time.time() - t0
        ok = r.returncode == 0
        results.append((name, ok, dt))
        print('%-16s %s  %6.0f s  %s' % (name, 'PASS' if ok else 'FAIL', dt, what), flush=True)
        if not ok:
            last = [l for l in r.stdout.strip().splitlines() if l.strip()]
            print('\n'.join('    ' + l for l in (last[-20:] + r.stderr.strip().splitlines()[-5:])))
    nfail = sum(1 for r in results if not r[1])
    print('REGRESSION %s: %d tests, %d failed, %.0f min%s' % ('PASS' if nfail == 0 else 'FAIL', len(results), nfail,
                                                            (time.time() - t_all) / 60, ' (quick)' if quick else ''))
    return 1 if nfail else 0


if __name__ == '__main__':
    sys.exit(main())
