#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_omac_40g.py - omac_40g system tests (xsim tb_omac_40g: two IPs back to
# back, four lanes each way through lane skew, a lane permutation and bit-level
# channel models, receiver lanes on their own recovered clocks, A and B 100 ppm
# apart). Each test prints its checks and one PASS/FAIL line.
#   frames     600 random frames each way (60-9000 bytes), random permutation, skew
#              and 66-bit phase per lane; the four A -> B lanes as B receives them
#              decoded by the independent Python model (markers, BIP, deskew,
#              reorder, descramble, clause 82 decode, XLGMII frames, IPG / DIC)
#   perms      all 24 lane orders in a random order, random skew up to the limit:
#              relock and 25 frames each (600 frames), exact
#   skew       skew beyond DESKEW_MAX: no alignment; back within: relock, frames
#   lanefail   one lane dies: local fault at B, remote fault at A; recovery
#   hiber      header errors on one lane: low rate no hi_ber, high rate hi_ber, clear
#   errors     TX aborts / underflows -> bad frames; payload bit flips on one lane ->
#              FCS errors and BIP errors; everything else exact
#   overflow   B's user side stops reading: frames truncated / dropped, never corrupt
#   runt       runts (TX padding off at A) and oversize frames (MAX_FRAME 1518 at B)
#   pause      PAUSE at 40G: XOFF 100 quanta = 200 cycles, XON, refresh, honour, contents
#   fault      Local Fault in -> Remote Fault out; Remote Fault -> idles; recovery
#   rate       10,000 minimum frames and 1,000 maximum frames back to back: line rate
#   watchdog   no lock -> gt_rx_reset_req pulses
# Usage: test_omac_40g.py [test ...] [--seed N] [--quick]
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
SRCS = S.ip_files('omac_40g') + [os.path.join(ROOT, 'ip', 'omac_10g', 'sim', 'tb_gt_chan.sv'),
                                 os.path.join(HERE, 'tb_omac_40g.sv')]
INC = os.path.join(ROOT, 'sim')
DESKEW_MAX = 32


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


def run(tag, generics, plusargs, seed, timeout=7200):
    d = os.path.join(S.BUILD, 'omac_40g', tag)
    os.makedirs(d, exist_ok=True)
    g = dict(AM_PERIOD=16384, A_TX_PAD=1, B_MAX_FRAME=9600, WD=2097152, DESKEW_MAX=DESKEW_MAX, BER_TIMER=195313)
    g.update(generics)
    bdir = os.path.join(S.BUILD, 'omac_40g', 'b_' + '_'.join('%s%d' % kv for kv in sorted(g.items())))
    out, log = S.xsim(bdir, 'tb_omac_40g', g, SRCS, [p.replace('@', d + '/') for p in plusargs], timeout, seed,
                      incdirs=[INC])
    with open(os.path.join(d, 'xsim.log'), 'w') as f:
        f.write(log)
    return out, d


def counts(out, who):
    v = S.tb_values(out, 'CNT_' + who)
    return v[0] if v else {}


def rx_compare(ck, exp, got, label):
    """exp: list of (expect_bad, bytes or None); got: list of (user, bytes)."""
    ck(len(got) == len(exp), '%s: %d frames received, %d expected' % (label, len(got), len(exp)))
    bad = 0
    for i, ((eb, eby), (u, gb)) in enumerate(zip(exp, got)):
        if eb is None:
            continue
        if bool(u) != eb or (not eb and gb != eby):
            if bad < 3:
                print('      frame %d: user %d (expected %d), len %d (expected %d)' % (i, u, eb, len(gb),
                                                                                    len(eby) if eby else -1))
            bad += 1
    ck(bad == 0, '%s: %d frame mismatches' % (label, bad))


def link_ok(ck, out):
    link = S.tb_values(out, 'LINK')
    ok = bool(link) and link[0]['a'] > 0 and link[0]['b'] > 0
    ck(ok, 'alignment + link up from random phases, lane order and skew: A %s, B %s cycles'
       % (link[0]['a'] if link else '?', link[0]['b'] if link else '?'))
    return link[0] if link else {}


def std_frames(rng, n, lo=60, hi=9000, b2b=0.5):
    fr = []
    for i in range(n):
        if i < int(n * b2b):
            ln, gap = rng.randint(lo, 400), 0
        else:
            ln = rng.choice([rng.randint(lo, 1518), rng.randint(lo, hi), rng.randint(lo, 200)])
            gap = rng.choice([0, 0, rng.randint(1, 40)])
        fr.append(dict(b=rnd_frame(rng, ln), gap=gap))
    return fr


def perm_src(k):
    pool, src = [0, 1, 2, 3], []
    for f in (6, 2, 1, 1):
        src.append(pool.pop(k // f))
        k %= f
    return src


# ---------------------------------------------------------------- frames
def t_frames(seed, quick):
    ck = Check('frames')
    rng = random.Random(seed)
    n = 200 if quick else 600
    fa = std_frames(rng, n)
    fb = [dict(b=rnd_frame(rng, rng.choice([rng.randint(60, 1518), rng.randint(60, 9000)])), gap=rng.randint(0, 20))
          for _ in range(n)]
    perm = rng.randrange(24)
    skew = [rng.randint(0, DESKEW_MAX - 3) for _ in range(4)]
    tag = 'frames_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_40g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    M.write_frames(os.path.join(d, 'fb.txt'), fb)
    out, d = run(tag, {}, ['mode=frames', 'fa=@fa.txt', 'fb=@fb.txt', 'oa=@oa.txt', 'ob=@ob.txt',
                           'cap=@cap.txt', 'capn=2000000', 'perm=%d' % perm, 'skew=%s' % ','.join(map(str, skew))],
                 seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    lk = link_ok(ck, out)
    src = perm_src(perm)
    # B's lane map: physical lane q carries PCS lane src[q]
    exp_map = sum(src[q] << (2 * q) for q in range(4))
    ck(lk.get('b_map') == exp_map, 'B found the lane order by the markers: map 0x%02x (physical lane q <- PCS lane %s)'
       % (lk.get('b_map', -1), src))
    sk_exp = max(skew) - min(skew)
    ck(lk and abs(lk.get('b_skew', -99) - sk_exp) <= 1, 'B measured skew %s blocks (applied %s: spread %d)'
       % (lk.get('b_skew'), skew, sk_exp))
    got_b = M.read_rx(os.path.join(d, 'ob.txt'))
    got_a = M.read_rx(os.path.join(d, 'oa.txt'))
    rx_compare(ck, [(False, pad60(f['b'])) for f in fa], got_b, 'A->B')
    rx_compare(ck, [(False, pad60(f['b'])) for f in fb], got_a, 'B->A')
    ca, cb = counts(out, 'A'), counts(out, 'B')
    ck(ca.get('txf') == n and cb.get('good') == n and cb.get('bad') == 0 and ca.get('good') == n,
       'events: A tx_frame %s, B rx good %s bad %s, A rx good %s' % (ca.get('txf'), cb.get('good'), cb.get('bad'),
                                                                   ca.get('good')))
    ck(cb.get('badblk') == 0 and ca.get('badblk') == 0 and cb.get('fcs') == 0 and cb.get('bip') == 0 and
       ca.get('bip') == 0 and cb.get('ovf') == 0, 'no bad blocks / FCS / BIP errors / overflows after link up')
    rxl = S.tb_values(out, 'RX')
    ck(bool(rxl) and rxl[0]['keep_err'] == 0, 'tkeep contiguous, full on non-last beats')
    frames, info = M.parse_capture_40g(os.path.join(d, 'cap.txt'))
    ck(info['lane_ids'] == src, 'Python decoder: lane ids by marker %s = applied permutation %s' % (info['lane_ids'], src))
    ck(info['ams'] >= 12 and info['spacing_err'] == 0 and info['bip_err'] == 0 and info['align_err'] == 0,
       'Python decoder: %d markers, period 16384 on every lane (%d errors), BIP3/BIP7 (%d errors), aligned after '
       'deskew (%d errors)' % (info['ams'], info['spacing_err'], info['bip_err'], info['align_err']))
    ck(info['skew'] == sk_exp, 'Python decoder: lane skew %s = applied %d' % (info['skew'], sk_exp))
    ck(info['invalid'] == 0, 'Python decoder: %d invalid blocks (clause 82 subset) in %d frames'
       % (info['invalid'], len(frames)))
    okf = sum(1 for f in frames if f[1])
    ck(okf == len(frames) and len(frames) >= n * 9 // 10, 'Python decoder: %d/%d frames with preamble, SFD, /T/, FCS ok'
       % (okf, len(frames)))
    ck(all(f[0] == pad60(x['b']) for f, x in zip(frames, fa)), 'Python decoder: frame contents = padded frames sent')
    ck(all(f[2] == 0 for f in frames), 'starts only in lane 0 of an 8-byte column')
    gaps = info['gaps']
    g = gaps[:int(n * 0.5) - 2]
    mean = sum(g) / max(1, len(g))
    runs_ok = all(sum(g[:k]) >= 12 * k - 7 for k in range(1, len(g) + 1))
    ck(bool(g) and min(gaps) >= 5 and runs_ok and mean <= 12.2,
       'IPG (from /T/ to /S/): min %d, mean %.3f over %d back-to-back frames (DIC: every prefix sum >= 12 n - 7)'
       % (min(gaps) if gaps else -1, mean, len(g)))
    return ck.done()


# ---------------------------------------------------------------- perms
def t_perms(seed, quick):
    ck = Check('perms')
    rng = random.Random(seed + 50)
    nper = 10 if quick else 25
    fa = [dict(b=rnd_frame(rng, rng.choice([rng.randint(60, 1518), rng.randint(60, 9000), rng.randint(60, 200)])),
               gap=rng.choice([0, 0, rng.randint(1, 20)])) for _ in range(24 * nper)]
    tag = 'perms_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_40g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    am = 2048
    out, d = run(tag, dict(AM_PERIOD=am), ['mode=perms', 'fa=@fa.txt', 'ob=@ob.txt', 'nper=%d' % nper], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    link_ok(ck, out)
    pp = S.tb_values(out, 'PERM')
    perms = sorted(p['perm'] for p in pp)
    ck(perms == list(range(24)), 'all 24 lane orders applied (%d)' % len(perms))
    bad = [p for p in pp if p['up'] < 0 or p['map'] != sum(int(str(p['src'])[q]) << (2 * q) for q in range(4))]
    ck(not bad, 'relock after every change, lane map = applied order (%d failures)' % len(bad))
    skok = 0
    for p in pp:
        sk = [int(x) for x in str(p['skew']).split(',')]
        if abs(p['measured'] - (max(sk) - min(sk))) <= 1:
            skok += 1
    ck(skok == len(pp), 'measured skew = applied spread (+-1) in %d/%d cases (max applied %d blocks)'
       % (skok, len(pp), max(max(int(x) for x in str(p['skew']).split(',')) for p in pp)))
    got = M.read_rx(os.path.join(d, 'ob.txt'))
    rx_compare(ck, [(False, pad60(f['b'])) for f in fa], got, 'A->B over 24 lane orders (marker period %d)' % am)
    return ck.done()


# ---------------------------------------------------------------- skew
def t_skew(seed, quick):
    ck = Check('skew')
    rng = random.Random(seed + 60)
    fa = [dict(b=rnd_frame(rng, rng.randint(60, 3000)), gap=rng.randint(0, 5)) for _ in range(50)]
    tag = 'skew_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_40g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    am = 2048
    out, d = run(tag, dict(AM_PERIOD=am), ['mode=skew', 'fa=@fa.txt', 'ob=@ob.txt', 'perm=9', 'skew=0,0,0,0'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    link_ok(ck, out)
    s1 = S.tb_values(out, 'SKEW1')[0]
    ck(s1['down_after'] > 0 and s1['no_align'] == 1 and s1['skew_fails'] >= 10 and s1['lf'] == 1 and s1['a_rf'] == 1,
       'skew %d blocks (> DESKEW_MAX %d): link down, no alignment for 12 marker periods (%d failed attempts), '
       'local fault at B, remote fault at A' % (DESKEW_MAX + 6, DESKEW_MAX, s1['skew_fails']))
    s2 = S.tb_values(out, 'SKEW2')[0]
    ck(s2['up_after'] > 0 and abs(s2['measured'] - (DESKEW_MAX - 4)) <= 1,
       'skew %d blocks: relock after %d cycles, measured %d' % (DESKEW_MAX - 4, s2['up_after'], s2['measured']))
    got = M.read_rx(os.path.join(d, 'ob.txt'))
    rx_compare(ck, [(False, pad60(f['b'])) for f in fa], got, 'A->B at %d blocks of skew' % (DESKEW_MAX - 4))
    return ck.done()


# ---------------------------------------------------------------- lane failure
def t_lanefail(seed, quick):
    ck = Check('lanefail')
    out, d = run('lanefail_s%d' % seed, {}, ['mode=lanefail', 'perm=5', 'skew=4,0,9,2'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    link_ok(ck, out)
    l1 = S.tb_values(out, 'LANE1')[0]
    ck(l1['down_after'] > 0 and l1['b_lock'] == 0 and l1['b_lf'] == 1 and str(l1['b_llock']) == '1011',
       'physical lane 2 dead: B lane block lock %s, no alignment, local fault, link down after %d cycles'
       % (l1['b_llock'], l1['down_after']))
    ck(l1['b_out_rf'] == 1 and l1['a_rf'] == 1 and l1['a_link'] == 0, 'B transmits Remote Fault, A remote fault, link down')
    r1 = S.tb_values(out, 'LANE1R')[0]
    ck(r1['a'] > 0 and r1['b'] > 0, 'lane back: block lock, AM lock, deskew, link up after %d / %d cycles'
       % (r1['a'], r1['b']))
    return ck.done()


# ---------------------------------------------------------------- hi_ber
def t_hiber(seed, quick):
    ck = Check('hiber')
    bt = 195313
    out, d = run('hiber_s%d' % seed, {}, ['mode=hiber'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    link_ok(ck, out)
    h1 = S.tb_values(out, 'HIBER1')[0]
    ck(h1['no_hiber'] == 1 and h1['lock'] == 1, '1 bad header / 8000 blocks on one lane (%d in 2 windows of 1.25 ms): '
       'no hi_ber, alignment kept' % h1['hdr_errs'])
    h2 = S.tb_values(out, 'HIBER2')[0]
    ck(0 < h2['set_after'] < bt and h2['b_link'] == 0 and h2['b_lf'] == 1 and h2['a_rf'] == 1 and h2['lock'] == 1,
       '1 / 150 blocks on one lane: hi_ber after %d cycles (97 within 1.25 ms), link down, local fault at B, remote '
       'fault at A, alignment kept' % h2['set_after'])
    h3 = S.tb_values(out, 'HIBER3')[0]
    ck(0 <= h3['clr_after'] <= 2 * bt and h3['link_a'] > 0 and h3['link_b'] > 0,
       'errors off: hi_ber clears after %d cycles (<= 2 windows), link up again' % h3['clr_after'])
    return ck.done()


# ---------------------------------------------------------------- errors
def t_errors(seed, quick):
    ck = Check('errors')
    rng = random.Random(seed + 100)
    n = 100 if quick else 250
    fa, fb, exp_b = [], [], []
    for i in range(n):
        ln = rng.randint(100, 3000)
        nb = (ln + 31) // 32
        f = dict(b=rnd_frame(rng, ln), gap=rng.randint(0, 10))
        k = rng.random()
        if k < 0.15:
            f['abort'] = rng.randint(1, nb - 1)
        elif k < 0.3:
            f['under'] = rng.randint(2, nb - 1)
        fa.append(f)
        exp_b.append((('abort' in f) or ('under' in f), pad60(f['b'])))
    for i in range(n):
        fb.append(dict(b=rnd_frame(rng, rng.randint(200, 3000)), gap=rng.randint(0, 10)))
    tag = 'errors_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_40g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    M.write_frames(os.path.join(d, 'fb.txt'), fb)
    out, d = run(tag, {}, ['mode=errors', 'fa=@fa.txt', 'fb=@fb.txt', 'oa=@oa.txt', 'ob=@ob.txt', 'perm=13',
                           'skew=1,7,0,3'], seed)
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
    ck(len(got_a) == n, 'B->A: %d frames received with %d payload bit flips on one lane' % (len(got_a), inj))
    ck(nbad == inj and inj > 0, 'B->A: %d bad frames = %d injected flips' % (nbad, inj))
    ck(all(g == pad60(f['b']) for (u, g), f in zip(got_a, fb) if not u), 'B->A: good frames exact')
    ck(ca.get('bad') == inj and ca.get('fcs') == inj, 'A events: bad %s, FCS errors %s' % (ca.get('bad'), ca.get('fcs')))
    ck(0 < ca.get('bip', 0) <= inj, 'A: %s BIP errors (one per marker period of the lane with a flip)' % ca.get('bip'))
    return ck.done()


# ---------------------------------------------------------------- overflow
def t_overflow(seed, quick):
    ck = Check('overflow')
    rng = random.Random(seed + 300)
    fa = [dict(b=rnd_frame(rng, rng.randint(60, 2000)), gap=rng.randint(0, 3)) for _ in range(400)]
    tag = 'overflow_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_40g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    out, d = run(tag, {}, ['mode=overflow', 'fa=@fa.txt', 'ob=@ob.txt'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    got = M.read_rx(os.path.join(d, 'ob.txt'))
    cb = counts(out, 'B')
    # delivered frames are a subsequence of the sent ones: good ones exact, bad ones a prefix (+1 byte)
    sent = [pad60(f['b']) for f in fa]
    i = j = 0
    corrupt = 0
    ngood = nbad = 0
    while j < len(got):
        u, g = got[j]
        while i < len(sent) and not ((not u and g == sent[i]) or (u and g[:-1] == sent[i][:len(g) - 1])):
            i += 1
        if i >= len(sent):
            corrupt += 1
            j += 1
            continue
        ngood += 0 if u else 1
        nbad += 1 if u else 0
        i += 1
        j += 1
    ndrop = len(sent) - len(got)
    ck(corrupt == 0, 'every delivered frame is a sent frame in order: good ones exact, cut ones a prefix (%d '
       'unmatched)' % corrupt)
    ck(cb.get('ovf', 0) > 0 and cb.get('ovf') == nbad + ndrop, 'B: %s overflow events = %d cut + %d dropped frames'
       % (cb.get('ovf'), nbad, ndrop))
    ck(cb.get('good') == ngood and ngood >= len(sent) - cb.get('ovf', 0) - 2,
       'B: %s good frames delivered (%d sent), the rest cut or dropped while the reader stalled' % (cb.get('good'),
                                                                                                    len(sent)))
    return ck.done()


# ---------------------------------------------------------------- runt / oversize
def t_runt(seed, quick):
    ck = Check('runt_oversize')
    rng = random.Random(seed + 200)
    n = 80 if quick else 200
    fa, exp = [], []
    nr = no = nsmall = 0
    for i in range(n):
        k = rng.random()
        if k < 0.3:
            ln = rng.randint(20, 59)
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
    d = os.path.join(S.BUILD, 'omac_40g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    out, d = run(tag, dict(A_TX_PAD=0, B_MAX_FRAME=1518), ['mode=frames', 'fa=@fa.txt', 'ob=@ob.txt'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    got = M.read_rx(os.path.join(d, 'ob.txt'))
    rx_compare(ck, exp, got, 'A->B (%d runts of 24-63 bytes, %d oversize)' % (nr, no))
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
def t_pause(seed, quick):
    ck = Check('pause40')
    tag = 'pause_s%d' % seed
    out, d = run(tag, {}, ['mode=pause', 'ob=@ob.txt', 'cap=@cap.txt', 'capn=40000'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    pz = [p['cycles'] for p in S.tb_values(out, 'PAUSE')]
    ck(len(pz) == 3, 'three PAUSE periods at B: %s cycles' % pz)
    if len(pz) == 3:
        ck(abs(pz[0] - 200) <= 2, 'XOFF 100 quanta: rx_pause_req %d cycles = %.1f ns (100 x 512 bit times = 1280 ns at 40G)'
           % (pz[0], pz[0] * 6.4))
        ck(1950 <= pz[1] <= 2150, 'XOFF 65535 then XON after 2000 cycles: held %d cycles' % pz[1])
        ck(9900 <= pz[2] <= 10150, 'XOFF 200 refreshed every 100 quanta for 10000 cycles: one period of %d cycles' % pz[2])
    st = S.tb_values(out, 'PSTARTS')[0]
    ck(st['total'] > 20 and st['in_pause'] == 0, 'B honours PAUSE: %d frame starts, %d while paused' % (st['total'], st['in_pause']))
    frames, info = M.parse_capture_40g(os.path.join(d, 'cap.txt'))
    pf = [f for f in frames if M.pause_fields(f[0])[2] == 0x8808]
    times = [M.pause_fields(f[0])[4] for f in pf]
    ok = all(f[1] and len(f[0]) == 60 and M.pause_fields(f[0])[:2] == (bytes.fromhex('0180c2000001'), MAC_A) and
             M.pause_fields(f[0])[3] == 1 and f[0][18:] == bytes(42) for f in pf)
    ck(ok and len(pf) > 0, 'PAUSE frames on A\'s lanes (Python decoder): DA 01-80-C2-00-00-01, SA, 0x8808, opcode 1, '
       '42 zero bytes, FCS (%d frames)' % len(pf))
    n200 = sum(1 for t in times if t == 200)
    exp_seq = [100, 0, 65535, 0] + [200] * n200 + [0]
    ck(times == exp_seq and n200 >= 40, 'pause_time sequence: 100, XON, 65535, XON, 200 x %d (refresh), XON' % n200)
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
       'B sends Local Fault: A local_fault, link down, A transmits Remote Fault (0x4B ordered sets)')
    ck(f1['b_rf'] == 1 and f1['b_link'] == 0, 'B sees Remote Fault, link down')
    r1 = S.tb_values(out, 'FAULT1R')[0]
    ck(r1['a'] > 0 and r1['b'] > 0, 'recovery after the fault: %d / %d cycles' % (r1['a'], r1['b']))
    f2 = S.tb_values(out, 'FAULT2')[0]
    ck(f2['a_lock'] == 0 and f2['a_lf'] == 1 and f2['b_rf'] == 1 and f2['b_link'] == 0,
       'A receiver broken (all lanes): A local fault (own PCS), B remote fault')
    ck(f2['b_idles'] == 1, 'B transmits idles while in Remote Fault (frames offered and discarded)')
    r2 = S.tb_values(out, 'FAULT2R')[0]
    ck(r2['a'] > 0 and r2['b'] > 0, 'recovery: %d / %d cycles' % (r2['a'], r2['b']))
    return ck.done()


# ---------------------------------------------------------------- rate
def t_rate(seed, quick):
    ck = Check('rate')
    rng = random.Random(seed + 400)
    nmin, nmax = (2000, 200) if quick else (10000, 1000)
    lmax = 9600 - 4
    fa = [dict(b=rnd_frame(rng, 60), gap=0) for _ in range(nmin)]
    fa += [dict(b=rnd_frame(rng, lmax), gap=0) for _ in range(nmax)]
    tag = 'rate_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_40g', tag)
    os.makedirs(d, exist_ok=True)
    M.write_frames(os.path.join(d, 'fa.txt'), fa)
    out, d = run(tag, {}, ['mode=rate', 'fa=@fa.txt', 'ob=@ob.txt', 'nmin=%d' % nmin, 'cap=@cap.txt',
                           'capn=200000', 'perm=22', 'skew=5,0,17,11'], seed)
    print('   ', out.replace('\n', '\n    '))
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    rt = {r['grp']: r for r in S.tb_values(out, 'RATE')}
    for grp, ln, nfr in (('min', 64, nmin), ('max', 9600, nmax)):
        r = rt.get(grp)
        if not r:
            ck(False, '%s: no rate record' % grp)
            continue
        wire = (ln + 20) * (r['n'] - 1) / 32.0          # 8 preamble + 12 average IPG, 32 bytes per cycle
        ideal = wire * 16384 / 16383.0                  # one marker cycle per 16384
        eff = wire / r['cycles']
        ck(r['cycles'] <= ideal + 4,
           '%d frames of %d bytes back to back: %d cycles for %d intervals, ideal %.1f (line rate less markers): '
           '%.4f of 40 Gb/s, %.3f Gb/s of frame bits' % (r['n'], ln, r['cycles'], r['n'] - 1, ideal, eff,
                                                       40.0 * eff * ln / (ln + 20)))
    got = M.read_rx(os.path.join(d, 'ob.txt'))
    rx_compare(ck, [(False, pad60(f['b'])) for f in fa], got, 'B receives every frame at line rate')
    cb = counts(out, 'B')
    ck(cb.get('good') == nmin + nmax and cb.get('ovf') == 0, 'B: %s good, %s overflows' % (cb.get('good'), cb.get('ovf')))
    frames, info = M.parse_capture_40g(os.path.join(d, 'cap.txt'))
    g = info['gaps'][2:-2]
    ck(len(g) > 1000 and min(g) >= 5 and abs(sum(g) / len(g) - 12.0) < 0.01,
       'Python decoder on the minimum-frame stream: %d gaps, min %d, mean %.4f (DIC average 12)'
       % (len(g), min(g) if g else -1, sum(g) / max(1, len(g))))
    return ck.done()


# ---------------------------------------------------------------- watchdog
def t_watchdog(seed, quick):
    ck = Check('watchdog')
    out, d = run('wd_s%d' % seed, dict(WD=60000, AM_PERIOD=2048), ['mode=watchdog'], seed)
    print('   ', out.replace('\n', '\n    '))
    w = S.tb_values(out, 'WD')[0]
    ck(w['b_pulses'] >= 2 and w['b_lock'] == 0 and w['a_pulses'] <= 1 and w['a_lock'] == 1,
       'no lock at B: %d gt_rx_reset_req pulses in 3 watchdog periods; A aligned (%d pulse during its search)'
       % (w['b_pulses'], w['a_pulses']))
    return ck.done()


TESTS = {
    'frames': t_frames, 'perms': t_perms, 'skew': t_skew, 'lanefail': t_lanefail, 'hiber': t_hiber,
    'errors': t_errors, 'overflow': t_overflow, 'runt': t_runt, 'pause': t_pause, 'fault': t_fault,
    'rate': t_rate, 'watchdog': t_watchdog,
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
    print('OMAC_40G TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
