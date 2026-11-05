#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_omac_10g.py - omac_10g system tests (xsim tb_omac_10g: two IPs back to
# back through bit-level channel models on clocks 100 ppm apart). Each test
# prints its checks and one PASS/FAIL line; the exit code is the failure count.
#   frames     random frames both ways (1-9000 bytes, padding), block lock from
#              random phases, A's transmit stream decoded by the independent
#              Python model (omac_ref: descrambler, figure 49-7 decoder, preamble,
#              SFD, FCS, start lanes, average IPG = 12 with the deficit idle count)
#   errors     TX aborts (tuser) and underflows -> bad frames; payload bit flips
#              on the line -> FCS errors; everything else exact
#   runt       runts (TX padding off at A) and oversize frames (MAX_FRAME 1518 at B)
#   pause      XOFF timing (100 quanta = 800 cycles), XON cancel, refresh, honour
#              (no frame start at B while paused), PAUSE frame contents, PAUSE
#              frames consumed; at 10G (6.4 ns) and 25G (2.56 ns)
#   fault      Local Fault in -> Remote Fault out; Remote Fault -> idles; recovery
#   hiber      BER monitor: low rate no hi_ber, high rate hi_ber, clears, relock
#   watchdog   no lock -> gt_rx_reset_req pulses
# Usage: test_omac_10g.py [test ...] [--seed N] [--quick]
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(ROOT, 'sim'))
import omac_ref as M  # noqa: E402
import simlib as S  # noqa: E402

MAC_A = bytes.fromhex('0200abcdef01')
SRCS = S.ip_files('omac_10g') + [os.path.join(HERE, 'tb_gt_chan.sv'), os.path.join(HERE, 'tb_omac_10g.sv')]
INC = os.path.join(ROOT, 'sim')


def pad60(b):
    return b + bytes(max(0, 60 - len(b)))


def rnd_frame(rng, ln):
    return bytes(rng.getrandbits(8) for _ in range(ln))


class Check:
    def __init__(self, name):
        self.name, self.fails = name, 0

    def __call__(self, cond, what):
        print('    %-4s %s' % ('ok' if cond else 'FAIL', what))
        if not cond:
            self.fails += 1

    def done(self):
        print('%s %s' % (self.name, 'PASS' if self.fails == 0 else 'FAIL (%d)' % self.fails))
        return self.fails


def run(tag, generics, plusargs, seed, timeout=3600):
    d = os.path.join(S.BUILD, 'omac_10g', tag)
    os.makedirs(d, exist_ok=True)
    g = dict(SPEED=10, A_TX_PAD=1, B_MAX_FRAME=9600, WD=2097152)
    g.update(generics)
    bdir = os.path.join(S.BUILD, 'omac_10g', 'b_' + '_'.join('%s%d' % kv for kv in sorted(g.items())))
    out, log = S.xsim(bdir, 'tb_omac_10g', g, SRCS, [p.replace('@', d + '/') for p in plusargs], timeout, seed,
                      incdirs=[INC])
    with open(os.path.join(d, 'xsim.log'), 'w') as f:
        f.write(log)
    return out, d


def counts(out, who):
    return S.tb_values(out, 'CNT_' + who)[0] if S.tb_values(out, 'CNT_' + who) else {}


def rx_compare(ck, exp, got, label):
    """exp: list of (expect_bad, bytes or None); got: list of (user, bytes)."""
    ck(len(got) == len(exp), '%s: %d frames received, %d expected' % (label, len(got), len(exp)))
    bad = 0
    for i, ((eb, eby), (u, gb)) in enumerate(zip(exp, got)):
        if eb is None:
            continue
        if bool(u) != eb or (not eb and gb != eby):
            if bad < 3:
                print('      frame %d: user %d (expected %d), len %d (expected %d)' % (i, u, eb, len(gb), len(eby)))
            bad += 1
    ck(bad == 0, '%s: %d frame mismatches' % (label, bad))


# ---------------------------------------------------------------- frames
def t_frames(seed, quick, speed=10):
    ck = Check('frames%s' % ('' if speed == 10 else '25'))
    rng = random.Random(seed)
    n = 120 if quick else 300
    fa, fb = [], []
    for i in range(n):
        if i < n // 2:      # back to back, short: inter-packet gap / DIC measurement
            ln, gap = rng.randint(60, 300), 0
        else:
            ln = rng.choice([rng.randint(1, 59), rng.randint(60, 1518), rng.randint(60, 9000), rng.randint(60, 200)])
            gap = rng.choice([0, 0, rng.randint(1, 40)])
        fa.append(dict(b=rnd_frame(rng, ln), gap=gap))
    for i in range(n):
        ln = rng.choice([rng.randint(1, 59), rng.randint(60, 1518), rng.randint(60, 9000)])
        fb.append(dict(b=rnd_frame(rng, ln), gap=rng.randint(0, 20)))
    tag = 'frames%d_s%d' % (speed, seed)
    d = os.path.join(S.BUILD, 'omac_10g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    M.write_frames(os.path.join(d, 'fb.txt'), fb)
    out, d = run(tag, dict(SPEED=speed), ['mode=frames', 'fa=@fa.txt', 'fb=@fb.txt', 'oa=@oa.txt', 'ob=@ob.txt',
                                          'cap=@cap.txt', 'capn=400000'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    link = S.tb_values(out, 'LINK')
    if link:
        ck(link[0]['a'] > 0 and link[0]['b'] > 0, 'block lock + link up from random phases: A %d, B %d cycles (%d / %d slips)'
           % (link[0]['a'], link[0]['b'], link[0]['slips_ba'], link[0]['slips_ab']))
    got_b = M.read_rx(os.path.join(d, 'ob.txt'))
    got_a = M.read_rx(os.path.join(d, 'oa.txt'))
    rx_compare(ck, [(False, pad60(f['b'])) for f in fa], got_b, 'A->B')
    rx_compare(ck, [(False, pad60(f['b'])) for f in fb], got_a, 'B->A')
    ca, cb = counts(out, 'A'), counts(out, 'B')
    ck(ca.get('txf') == n and cb.get('good') == n and cb.get('bad') == 0, 'events: A tx_frame %s, B rx good %s bad %s'
       % (ca.get('txf'), cb.get('good'), cb.get('bad')))
    ck(cb.get('badblk') == 0 and ca.get('badblk') == 0 and cb.get('fcs') == 0, 'no bad blocks / FCS errors after link up')
    rxl = S.tb_values(out, 'RX')
    ck(bool(rxl) and rxl[0]['keep_err'] == 0, 'tkeep contiguous, full on non-last beats')
    # independent decode of A's transmitted blocks
    frames, info = M.parse_capture(os.path.join(d, 'cap.txt'))
    ck(info['invalid'] == 0, 'Python decoder: %d invalid blocks in %d frames' % (info['invalid'], len(frames)))
    okf = sum(1 for f in frames if f[1])
    ck(okf == len(frames) and len(frames) >= n * 3 // 4, 'Python decoder: %d/%d frames with preamble, SFD, /T/, FCS ok'
       % (okf, len(frames)))
    ck(all(f[0] == pad60(x['b']) for f, x in zip(frames, fa)), 'Python decoder: frame contents = padded frames sent')
    ck(all(f[2] in (0, 4) for f in frames), 'starts in lane 0 or 4 (lane 4: %d)' % sum(1 for f in frames if f[2] == 4))
    g = info['gaps'][:n // 2 - 2]
    mean = sum(g) / max(1, len(g))
    # deficit idle count: every gap >= 9, and over any run the deficit is at most 3 bytes
    ck(min(info['gaps']) >= 9 and sum(g) >= 12 * len(g) - 3 and mean <= 12.5,
       'IPG (from /T/ to /S/): min %d, mean %.3f over %d back-to-back frames (DIC: sum >= 12 n - 3)'
       % (min(info['gaps']), mean, len(g)))
    return ck.done()


# ---------------------------------------------------------------- errors
def t_errors(seed, quick):
    ck = Check('errors')
    rng = random.Random(seed + 100)
    n = 100 if quick else 250
    fa, fb, exp_b = [], [], []
    for i in range(n):
        ln = rng.randint(60, 2000)
        nb = (ln + 7) // 8
        f = dict(b=rnd_frame(rng, ln), gap=rng.randint(0, 10))
        k = rng.random()
        if k < 0.15:
            f['abort'] = rng.randint(2, nb - 1)
        elif k < 0.3:
            f['under'] = rng.randint(2, nb - 1)
        fa.append(f)
        exp_b.append((('abort' in f) or ('under' in f), pad60(f['b'])))
    for i in range(n):
        fb.append(dict(b=rnd_frame(rng, rng.randint(200, 3000)), gap=rng.randint(0, 10)))
    tag = 'errors_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_10g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    M.write_frames(os.path.join(d, 'fb.txt'), fb)
    out, d = run(tag, {}, ['mode=errors', 'fa=@fa.txt', 'fb=@fb.txt', 'oa=@oa.txt', 'ob=@ob.txt'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    n_ab = sum(1 for f in fa if 'abort' in f)
    n_un = sum(1 for f in fa if 'under' in f)
    rx_compare(ck, exp_b, M.read_rx(os.path.join(d, 'ob.txt')), 'A->B (%d aborts, %d underflows)' % (n_ab, n_un))
    ca, cb = counts(out, 'A'), counts(out, 'B')
    ck(ca.get('abt') == n_ab and ca.get('und') == n_un, 'A events: abort %s (%d), underflow %s (%d)'
       % (ca.get('abt'), n_ab, ca.get('und'), n_un))
    ck(cb.get('bad') == n_ab + n_un and cb.get('good') == n - n_ab - n_un, 'B events: good %s bad %s'
       % (cb.get('good'), cb.get('bad')))
    inj = S.tb_values(out, 'INJ')[0]['dflip_ba']
    got_a = M.read_rx(os.path.join(d, 'oa.txt'))
    nbad = sum(1 for u, _ in got_a if u)
    ck(len(got_a) == n, 'B->A: %d frames received with %d line bit flips' % (len(got_a), inj))
    ck(nbad == inj and inj > 0, 'B->A: %d bad frames = %d injected flips (at most one per frame)' % (nbad, inj))
    ck(all(g == pad60(f['b']) for (u, g), f in zip(got_a, fb) if not u), 'B->A: good frames exact')
    ck(ca.get('bad') == inj and ca.get('fcs') <= inj and ca.get('fcs') >= inj // 2,
       'A events: bad %s, FCS errors %s (the rest are flips that hit the /T/ block)' % (ca.get('bad'), ca.get('fcs')))
    return ck.done()


# ---------------------------------------------------------------- runt / oversize
def t_runt(seed, quick):
    ck = Check('runt_oversize')
    rng = random.Random(seed + 200)
    n = 80 if quick else 200
    fa, exp = [], []
    nr = no = 0
    for i in range(n):
        k = rng.random()
        if k < 0.3:
            ln = rng.randint(1, 59)
        elif k < 0.6:
            ln = rng.randint(1515, 3000)
        else:
            ln = rng.randint(60, 1514)
        b = rnd_frame(rng, ln)
        fa.append(dict(b=b, gap=rng.randint(0, 10)))
        if ln + 4 < 64:
            exp.append((True, b)); nr += 1
        elif ln + 4 > 1518:
            exp.append((True, None)); no += 1
        else:
            exp.append((False, b))
    tag = 'runt_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_10g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    out, d = run(tag, dict(A_TX_PAD=0, B_MAX_FRAME=1518), ['mode=frames', 'fa=@fa.txt', 'ob=@ob.txt'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    got = M.read_rx(os.path.join(d, 'ob.txt'))
    rx_compare(ck, exp, got, 'A->B (%d runts, %d oversize)' % (nr, no))
    over_ok = all(u == 1 and len(g) <= 1518 and g == f['b'][:len(g)] for (u, g), f, (eb, ey) in zip(got, fa, exp)
                  if ey is None)
    ck(over_ok, 'oversize frames cut at <= MAX_FRAME with tuser = 1, prefix exact')
    runt_ok = all(g == f['b'] for (u, g), f, (eb, ey) in zip(got, fa, exp) if eb and ey is not None)
    ck(runt_ok, 'runts delivered with tuser = 1, contents exact')
    cb = counts(out, 'B')
    ck(cb.get('runt') == nr and cb.get('over') == no and cb.get('fcs') == 0,
       'B events: runt %s (%d), oversize %s (%d), FCS errors %s' % (cb.get('runt'), nr, cb.get('over'), no, cb.get('fcs')))
    return ck.done()


# ---------------------------------------------------------------- pause
def t_pause(seed, quick, speed=10):
    ck = Check('pause%d' % speed)
    period = 2.56 if speed == 25 else 6.4
    tag = 'pause%d_s%d' % (speed, seed)
    out, d = run(tag, dict(SPEED=speed), ['mode=pause', 'ob=@ob.txt', 'cap=@cap.txt', 'capn=60000'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    pz = [p['cycles'] for p in S.tb_values(out, 'PAUSE')]
    ck(len(pz) == 3, 'three PAUSE periods at B: %s cycles' % pz)
    if len(pz) == 3:
        ck(abs(pz[0] - 800) <= 2, 'XOFF 100 quanta: rx_pause_req %d cycles = %.1f ns (100 x 512 bit times = %.1f ns at %dG)'
           % (pz[0], pz[0] * period, 100 * 512 / speed, speed))
        ck(1950 <= pz[1] <= 2150, 'XOFF 65535 then XON after 2000 cycles: held %d cycles' % pz[1])
        ck(9900 <= pz[2] <= 10150, 'XOFF 200 refreshed every 100 quanta for 10000 cycles: one period of %d cycles' % pz[2])
    st = S.tb_values(out, 'PSTARTS')[0]
    ck(st['total'] > 20 and st['in_pause'] == 0, 'B honours PAUSE: %d frame starts, %d while paused' % (st['total'], st['in_pause']))
    frames, info = M.parse_capture(os.path.join(d, 'cap.txt'))
    pf = [f for f in frames if M.pause_fields(f[0])[2] == 0x8808]
    times = [M.pause_fields(f[0])[4] for f in pf]
    ok = all(f[1] and len(f[0]) == 60 and M.pause_fields(f[0])[:2] == (bytes.fromhex('0180c2000001'), MAC_A) and
             M.pause_fields(f[0])[3] == 1 and f[0][18:] == bytes(42) for f in pf)
    ck(ok and len(pf) > 0, 'PAUSE frames on A\'s wire: DA 01-80-C2-00-00-01, SA, 0x8808, opcode 1, 42 zero bytes, FCS (%d frames)'
       % len(pf))
    n200 = sum(1 for t in times if t == 200)
    exp_seq = [100, 0, 65535, 0] + [200] * n200 + [0]
    ck(times == exp_seq and n200 >= 11, 'pause_time sequence: 100, XON, 65535, XON, 200 x %d (refresh), XON' % n200)
    cb = counts(out, 'B')
    rx = S.tb_values(out, 'RX')[0]
    ck(cb.get('rxp') == len(pf) and rx['ctrl_seen'] == 0, 'B: %s PAUSE frames received and consumed (none on the AXI-Stream)'
       % cb.get('rxp'))
    return ck.done()


# ---------------------------------------------------------------- fault
def t_fault(seed, quick):
    ck = Check('fault')
    out, d = run('fault_s%d' % seed, {}, ['mode=fault'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    f1 = S.tb_values(out, 'FAULT1')[0]
    ck(f1['a_lf'] == 1 and f1['a_link'] == 0 and f1['a_out_rf'] == 1,
       'B sends Local Fault: A local_fault, link down, A transmits Remote Fault')
    ck(f1['b_rf'] == 1 and f1['b_link'] == 0, 'B sees Remote Fault, link down')
    r1 = S.tb_values(out, 'FAULT1R')[0]
    ck(r1['a'] > 0 and r1['b'] > 0, 'recovery after the fault: %d / %d cycles' % (r1['a'], r1['b']))
    f2 = S.tb_values(out, 'FAULT2')[0]
    ck(f2['a_lock'] == 0 and f2['a_lf'] == 1 and f2['b_rf'] == 1 and f2['b_link'] == 0,
       'A receiver broken: A local fault (own PCS), B remote fault')
    ck(f2['b_idles'] == 1, 'B transmits idles while in Remote Fault (frames offered and discarded)')
    r2 = S.tb_values(out, 'FAULT2R')[0]
    ck(r2['a'] > 0 and r2['b'] > 0, 'recovery: %d / %d cycles' % (r2['a'], r2['b']))
    return ck.done()


# ---------------------------------------------------------------- hi_ber
def t_hiber(seed, quick):
    ck = Check('hiber')
    out, d = run('hiber_s%d' % seed, {}, ['mode=hiber'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    h1 = S.tb_values(out, 'HIBER1')[0]
    ck(h1['no_hiber'] == 1 and h1['lock'] == 1, '1 bad header / 4000 blocks (%d in 3 windows): no hi_ber, lock kept'
       % h1['hdr_errs'])
    h2 = S.tb_values(out, 'HIBER2')[0]
    ck(0 < h2['set_after'] < 19532 and h2['b_link'] == 0 and h2['b_lf'] == 1 and h2['a_rf'] == 1 and h2['lock'] == 1,
       '1 / 150 blocks: hi_ber after %d cycles, link down, local fault at B, remote fault at A, lock kept' % h2['set_after'])
    h3 = S.tb_values(out, 'HIBER3')[0]
    ck(0 <= h3['clr_after'] <= 2 * 19532 and h3['link_a'] > 0 and h3['link_b'] > 0,
       'errors off: hi_ber clears after %d cycles (<= 2 windows), link up again' % h3['clr_after'])
    h4 = S.tb_values(out, 'HIBER4')[0]
    ck(0 <= h4['lock_lost_after'] < 100 and h4['relink_b'] > 0,
       '20 invalid headers: lock lost after %d cycles, link back after %d' % (h4['lock_lost_after'], h4['relink_b']))
    return ck.done()


# ---------------------------------------------------------------- watchdog
def t_watchdog(seed, quick):
    ck = Check('watchdog')
    out, d = run('wd_s%d' % seed, dict(WD=5000), ['mode=watchdog'], seed)
    print('   ', out.replace('\n', '\n    '))
    w = S.tb_values(out, 'WD')[0]
    # A's initial lock search (up to 66 slips x SLIP_WAIT) may take longer than this short
    # watchdog (5000 cycles), so A may pulse once before it locks; never after
    ck(w['b_pulses'] >= 2 and w['b_lock'] == 0 and w['a_pulses'] <= 1 and w['a_lock'] == 1,
       'no lock at B: %d gt_rx_reset_req pulses in 3 watchdog periods; A locked (%d pulse during its lock search)'
       % (w['b_pulses'], w['a_pulses']))
    return ck.done()


TESTS = {
    'frames': lambda s, q: t_frames(s, q, 10),
    'frames25': lambda s, q: t_frames(s, True, 25),
    'errors': t_errors,
    'runt': t_runt,
    'pause10': lambda s, q: t_pause(s, q, 10),
    'pause25': lambda s, q: t_pause(s, q, 25),
    'fault': t_fault,
    'hiber': t_hiber,
    'watchdog': t_watchdog,
}


def main():
    args = sys.argv[1:]
    seed = 1
    if '--seed' in args:
        i = args.index('--seed')
        seed = int(args[i + 1])
        del args[i:i + 2]
    quick = '--quick' in args
    args = [a for a in args if a != '--quick']
    M.selftest()
    sel = args or list(TESTS)
    fails = 0
    for t in sel:
        print('== %s (seed %d)' % (t, seed), flush=True)
        fails += TESTS[t](seed, quick)
    print('OMAC_10G TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
