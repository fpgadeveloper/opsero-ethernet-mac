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
TMD = os.path.join(ROOT, 'ip', 'omac_mdio', 'sim', 'test_omac_mdio.py')
TMB = os.path.join(ROOT, 'ip', 'omac_mdio', 'drivers', 'baremetal', 'test', 'test_omac_mdio_drv.py')
T40 = os.path.join(ROOT, 'ip', 'omac_40g', 'sim', 'test_omac_40g.py')
U40 = os.path.join(ROOT, 'ip', 'omac_40g', 'sim', 'test_40g_units.py')
TGT = os.path.join(HERE, 'gt', 'test_gt.py')
TUX = os.path.join(ROOT, 'ip', 'omac_10g', 'sim', 'test_omac_10g_usx.py')
# transceiver-level tests (vendor GT models, slow): run only with --gt
GT_TESTS = [
    ('gt_gty_loop', TGT, ['gty', '40'], ['gty', '8'], 'omac_gt_usp_gty_quad, two lanes crossed: reset, CDR, '
     'gearbox slip, block lock, link up, frames both ways (GTY models, xcku5p)'),
    ('gt_gth_loop', TGT, ['gth', '40'], ['gth', '8'], 'omac_gt_usp_gth_quad, the same on GTH (xczu7ev, lane map 0x01)'),
    ('gt_versal_loop', TGT, ['versal', '40'], ['versal', '8'], 'omac_gt_versal_gty_quad, the same on Versal GTY '
     '(xcvc1902, gt_quad_base, quad channels 1 and 0)'),
    ('gt_versal_xh_loop', TGT, ['versal_xh', '40'], ['versal_xh', '8'], 'omac_gt_versal_gty_quad with one lane '
     'on each half-quad (quad channels 2 and 1: both reference clock inputs of the IP, TX master on HSCLK1)'),
]

# name: (script, full arguments, quick arguments, what it covers)
TESTS = [
    ('bd_wrapper', os.path.join(ROOT, 'scripts', 'gen_bd_wrapper.py'), ['--check'], ['--check'],
     'ip/<ip>/rtl/<ip>_bd.v are up to date with omac_10g.sv / omac_40g.sv / omac_mdio.sv'),
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
    # USXGMII (USXGMII_EN = 1)
    ('usx_axil', TUX, ['axil'], ['axil'], 'omac_10g_usx_axil register block: every register, strobes, W1C, irq, counters'),
    ('usx_speeds', TUX, ['speeds'], ['speeds', '--quick'], 'DUT vs PHY model: AN 10G -> 1G -> 2.5G -> 5G -> 100M -> '
     '10M on the fly, frames 60-9000 B both ways, FCS errors, aborts, idle insertion / deletion, LPI, lock loss, '
     'replication rules, timestamps'),
    ('usx_corrupt', TUX, ['corrupt'], ['corrupt', '--quick'], 'replica disagreement: counted once per frame, '
     'strict 0 = frames good, strict 1 = exactly those frames bad'),
    ('usx_forced', TUX, ['forced'], ['forced', '--quick'], 'AN off at both ends: forced 10G, 2.5G, 1G, 100M'),
    ('usx_antimer', TUX, ['antimer'], ['antimer'], 'the default 1.6 ms link timer: AN in 3 link timers'),
    ('usx_loop10g', T10, ['loop10g'], ['loop10g', '--quick'], 'USXGMII pair at 10G: AN, frames, errors, PAUSE, wire '
     'decode, DIC, timestamps'),
    ('usx_loop5g', T10, ['loop5g'], ['loop5g', '--quick'], 'the same at 5G (replication 2), wire decode with the '
     'replication rules'),
    ('usx_loop2p5g', T10, ['loop2p5g'], ['loop2p5g', '--quick'], 'the same at 2.5G (replication 4)'),
    ('usx_loop1g', T10, ['loop1g'], ['loop1g', '--quick'], 'the same at 1G (replication 10)'),
    ('usx_loop100m', T10, ['loop100m'], ['loop100m', '--quick'], 'the same at 100M (replication 100)'),
    ('usx_loop10m', T10, ['loop10m'], ['loop10m', '--quick'], 'the same at 10M (replication 1000)'),
    ('usx_pause1g', T10, ['pause_usx1g'], ['pause_usx1g'], 'PAUSE over USXGMII at 1G: quanta in 1G bit times '
     '(100 quanta = 8000 cycles), XON, refresh, honour, frame contents'),
    ('usx_pause2p5g', T10, ['pause_usx2p5g'], ['pause_usx2p5g'], 'the same at 2.5G'),
    ('10g_frames_usx', T10, ['frames', '--seed', '1', '--usx'], ['frames', '--seed', '1', '--quick', '--usx'],
     '10g_frames with USXGMII_EN = 1 (auto-negotiated 10G)'),
    ('10g_errors_usx', T10, ['errors', '--usx'], ['errors', '--quick', '--usx'], '10g_errors with USXGMII_EN = 1'),
    ('10g_runt_usx', T10, ['runt', '--usx'], ['runt', '--quick', '--usx'], '10g_runt with USXGMII_EN = 1'),
    ('10g_pause10_usx', T10, ['pause10', '--usx'], ['pause10', '--usx'], '10g_pause10 with USXGMII_EN = 1'),
    ('10g_fault_usx', T10, ['fault', '--usx'], ['fault', '--usx'], '10g_fault with USXGMII_EN = 1 (AN restart on '
     'lock loss)'),
    ('10g_hiber_usx', T10, ['hiber', '--usx'], ['hiber', '--usx'], '10g_hiber with USXGMII_EN = 1'),
    ('10g_watchdog_usx', T10, ['watchdog', '--usx'], ['watchdog', '--usx'], '10g_watchdog with USXGMII_EN = 1'),
    ('10g_ts_usx', T10, ['ts', '--usx'], ['ts', '--quick', '--usx'], '10g_ts with USXGMII_EN = 1'),
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
    ('mdio', TMD, ['base'], ['base', '--quick'], 'omac_mdio vs three PHY models: clause 22/45, all OPs, divider, '
     'preamble, free-running MDC, hold, abort + resync, bit-bang, irq, bus error (100 MHz, push-pull)'),
    ('mdio_fast', TMD, ['fast'], ['fast', '--quick'], 'the same at 250 MHz, OPEN_DRAIN = 1, 3 synchroniser stages'),
    ('mdio_drv', TMB, [], [], 'omac_mdio bare-metal driver: host unit test against a register model (cc)'),
]


def main():
    args = sys.argv[1:]
    quick = '--quick' in args
    sel = args[args.index('-k') + 1] if '-k' in args else None
    results = []
    t_all = time.time()
    for name, script, full, qargs, what in (GT_TESTS if '--gt' in args else TESTS):
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
