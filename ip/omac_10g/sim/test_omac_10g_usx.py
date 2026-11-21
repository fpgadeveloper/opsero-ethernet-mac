#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_omac_10g_usx.py - omac_10g USXGMII tests (USXGMII_EN = 1).
# DUT against the behavioural PHY model (xsim tb_omac_10g_usx + tb_usx_phy):
#   speeds    auto-negotiation through 10G -> 1G -> 2.5G -> 5G -> 100M -> 10M on
#             the fly (the PHY takes a new word, both restart, alternately the
#             whole exchange and the PHY's "re-signal"; both configuration
#             ordered-set formats), frames of 60-9000 bytes both ways, back to
#             back at the minimum gap, random payloads, wrong FCS from the PHY,
#             aborts / underflows from the DUT, idle insertion / deletion of
#             single 4-byte words by the PHY (start lane 0 / 4, replication
#             phase of the gap broken), LPI words between frames, a burst of
#             invalid sync headers (block lock lost, auto-negotiation restarted,
#             relink); every replication rule checked by the PHY model on the
#             DUT's stream; timestamps against the /S/ block of both directions
#   corrupt   one copy of a data word corrupted per frame (2.5G, 1G, 5G, 100M):
#             ev_usx_rep_error once per corrupted frame; ctl_usx_rx_strict = 0
#             keeps the frames good, = 1 makes exactly those frames bad
#   forced    auto-negotiation off at both ends, forced speeds (10G, 2.5G, 1G, 100M)
#   antimer   the default 1.6 ms link timer (USX_LINK_TIMER = 250000) at 1G
#   axil      unit test of the optional register block omac_10g_usx_axil
# DUT against DUT (xsim tb_omac_10g with USX = 1): see test_omac_10g.py
# (loop<speed>, and the plain tests with USX = 1).
# Usage: test_omac_10g_usx.py [test ...] [--seed N] [--quick]
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

SRCS = S.ip_files('omac_10g') + [os.path.join(HERE, f) for f in ('tb_gt_chan.sv', 'tb_usx_phy.sv',
                                                                 'tb_omac_10g_usx.sv')]
INC = os.path.join(ROOT, 'sim')
NAME = {3: '10G', 5: '5G', 4: '2.5G', 2: '1G', 1: '100M', 0: '10M'}
REP = {3: 1, 5: 2, 4: 4, 2: 10, 1: 100, 0: 1000}
CH_LAT = 3          # tb_gt_chan: a block on the PHY's tx_data in cycle c is on the DUT's gt_rx_data in c + 3
DUT_ADV = 0x9601    # the testbench's ctl_usx_an_adv


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


def rnd(rng, n):
    return bytes(rng.getrandbits(8) for _ in range(n))


def run(tag, generics, plusargs, seed, timeout=7200):
    d = os.path.join(S.BUILD, 'omac_10g_usx', tag)
    os.makedirs(d, exist_ok=True)
    g = dict(LT=2000)
    g.update(generics)
    bdir = os.path.join(S.BUILD, 'omac_10g_usx', 'b_' + '_'.join('%s%d' % kv for kv in sorted(g.items())))
    out, log = S.xsim(bdir, 'tb_omac_10g_usx', g, SRCS, [p.replace('@', d + '/') for p in plusargs], timeout, seed,
                      incdirs=[INC])
    with open(os.path.join(d, 'xsim.log'), 'w') as f:
        f.write(log)
    return out, log, d


def read_cols(path):
    def num(x):
        try:
            return int(x)
        except ValueError:
            return -1
    return [[num(x) if i < 3 else x for i, x in enumerate(l.split())] for l in open(path) if l.strip()]


def make_frames(rng, n, big=True):
    """n frames of 60..9000 bytes, mostly back to back; at least one 60, one 64, one 9000 if big."""
    sizes = [60, 64] + ([9000] if big else [])
    while len(sizes) < n:
        sizes.append(rng.choice([rng.randint(60, 128), rng.randint(60, 1518), rng.randint(60, 300),
                                 rng.randint(60, 9000) if big else rng.randint(60, 2000)]))
    rng.shuffle(sizes)
    return [dict(b=rnd(rng, s), gap=0 if rng.random() < 0.7 else rng.randint(1, 20)) for s in sizes[:n]]


def phase_files(d, p, fa, fb):
    M.write_frames(os.path.join(d, 'fa%d.txt' % p), fa)
    M.write_frames(os.path.join(d, 'fb%d.txt' % p), fb)
    return ['fa%d=@fa%d.txt' % (p, p), 'fb%d=@fb%d.txt' % (p, p)]


def pad60(b):
    return b + bytes(max(0, 60 - len(b)))


def check_run(ck, out, d, speeds, fa_all, fb_all, an, exp_rep=None, strict=None):
    """Common checks. fa_all / fb_all: per phase the frames the DUT / the PHY sends
    (fb: dict with 'bad' = wrong FCS). exp_rep: per phase expected replica mismatches."""
    ck('TB_DONE' in out and 'TB_FAIL' not in out, 'simulation completed')
    ph = S.tb_values(out, 'PH')
    pe = S.tb_values(out, 'PE')
    ck(len(ph) == len(speeds) and len(pe) == len(speeds), '%d phases with link and frames' % len(speeds))
    oa = M.read_rx(os.path.join(d, 'oa.txt'))
    ra = read_cols(os.path.join(d, 'ra.txt'))
    ta = read_cols(os.path.join(d, 'ta.txt'))
    pr = read_cols(os.path.join(d, 'pr.txt'))
    ps = read_cols(os.path.join(d, 'ps.txt'))
    ia = ib = 0
    for p, (code, h, e) in enumerate(zip(speeds, ph, pe)):
        nm = NAME[code]
        ck(h['link'] == 1 and h['dut_speed'] == code, '%s: link, DUT speed code %d (%d cycles to link)'
           % (nm, h['dut_speed'], h['t']))
        if an:
            ck((h['lp_word'] >> 9) & 7 == code and h['lp_word'] & 0x9001 == 0x9001 and h['lp_word'] & 0x4000,
               '%s: DUT received word 0x%04x (link, full duplex, ack, speed %d)' % (nm, h['lp_word'], code))
            ck(h['phy_dut_word'] == DUT_ADV | 0x4000, '%s: PHY received the DUT word 0x%04x (adv + ack)'
               % (nm, h['phy_dut_word']))
        ck(h['phy_rep'] == REP[code], '%s: PHY replication %d' % (nm, h['phy_rep']))
        fa, fb = fa_all[p], fb_all[p]
        # PHY -> DUT
        got = oa[ia:ia + len(fb)]
        rts = ra[ia:ia + len(fb)]
        sent = ps[ia:ia + len(fb)]
        ia += len(fb)
        bad = 0
        for i, (f, g) in enumerate(zip(fb, got)):
            eb = f['bad'] or (strict is not None and strict[p] and sent[i][2] == 1)
            if bool(g[0]) != eb or (not eb and g[1] != f['b']):
                if bad < 3:
                    print('      %s PHY->DUT frame %d: user %d (expected %d), len %d (%d)' % (nm, i, g[0], eb,
                                                                                         len(g[1]), len(f['b'])))
                bad += 1
        ck(len(got) == len(fb) and bad == 0, '%s PHY->DUT: %d/%d frames, %d mismatches (%d wrong FCS sent, delivered '
           'bad)' % (nm, len(got), len(fb), bad, sum(1 for f in fb if f['bad'])))
        dts = sorted(set(r[0] - s[0] for r, s in zip(rts, sent)))
        ck(dts == [CH_LAT] and all(r[1] == (s[1] == 4) for r, s in zip(rts, sent)) and all(r[2] == 1 for r in rts),
           '%s PHY->DUT timestamps: RX ts - /S/ block cycle at the PHY = %s (channel %d), lane4 = /S/ lane '
           '(%d lane-4 starts), constant on every beat' % (nm, dts[:4], CH_LAT, sum(1 for s in sent if s[1] == 4)))
        # DUT -> PHY
        got = pr[ib:ib + len(fa)]
        tts = [t for t in ta if t[2] == 1][ib:ib + len(fa)]
        ib += len(fa)
        bad = 0
        for i, (f, g) in enumerate(zip(fa, got)):
            eb = 'abort' in f or 'under' in f
            gb = bytes.fromhex(g[3]) if len(g) > 3 else b''
            if bool(g[0]) == eb or (not eb and gb != pad60(f['b'])):
                if bad < 3:
                    print('      %s DUT->PHY frame %d: ok %d (bad expected %d), len %d (%d)' % (nm, i, g[0], eb,
                                                                                         len(gb), len(f['b'])))
                bad += 1
        nab = sum(1 for f in fa if 'abort' in f or 'under' in f)
        ck(len(got) == len(fa) and bad == 0, '%s DUT->PHY: %d/%d frames, %d mismatches (%d aborts / underflows '
           'arrive bad)' % (nm, len(got), len(fa), bad, nab))
        tdiff = sorted(set(t[0] - g[1] for t, g in zip(tts, got)))
        ck(tdiff == [0] and all(t[1] == (g[2] == 4) for t, g in zip(tts, got)),
           '%s DUT->PHY timestamps: TX ts = cycle of the /S/ block on gt_tx_data (%d frames, diff %s), lane4 = '
           '/S/ lane' % (nm, len(tts), tdiff[:4]))
        ck(e['phy_viol'] == 0 and e['phy_fill'] == 0 and e['phy_align'] == 0 and e['phy_gap'] == 0 and
           e['phy_slane'] == 0 and e['phy_dec'] == 0,
           '%s DUT stream at the PHY: replication rules (copies, 0xAA fill, idle copies of /T/, gap multiple of %d '
           'words, /S/ in lane 0%s), no invalid block' % (nm, REP[code], '' if REP[code] > 1 else ' or 4'))
        if e['ipg_n']:
            ck(e['ipg_min'] >= 9, '%s DUT gap at the link speed: min %d bytes, mean %.2f over %d gaps'
               % (nm, e['ipg_min'], e['ipg_sum'] / e['ipg_n'], e['ipg_n']))
        er = 0 if exp_rep is None else exp_rep[p]
        ck(e['rep_err'] == er, '%s ev_usx_rep_error %d (expected %d)' % (nm, e['rep_err'], er))
    c = S.tb_values(out, 'CNT')[0]
    ck(c['keep_err'] == 0 and c['tsc_err'] == 0, 'tkeep contiguous, RX timestamp constant on every beat')
    return c


# ---------------------------------------------------------------- speeds
def t_speeds(seed, quick):
    ck = Check('usx_speeds')
    rng = random.Random(seed + 500)
    speeds = [3, 2, 4, 5, 1, 0]
    nfr = {3: 60, 2: 24, 4: 30, 5: 40, 1: 8, 0: 4} if not quick else {3: 20, 2: 8, 4: 10, 5: 12, 1: 4, 0: 3}
    tag = 'speeds_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_10g_usx', tag)
    os.makedirs(d, exist_ok=True)
    pargs = []
    fa_all, fb_all = [], []
    for p, code in enumerate(speeds):
        big = not (quick and code in (0, 1))
        fa = make_frames(rng, nfr[code], big)
        for f in fa:
            nb = (len(f['b']) + 7) // 8
            k = rng.random()
            if nb > 4 and k < 0.06:
                f['abort'] = rng.randint(2, nb - 1)
            elif nb > 4 and k < 0.12:
                f['under'] = rng.randint(2, nb - 1)
        fb = make_frames(rng, nfr[code], big)
        for f in fb:
            f['bad'] = rng.random() < 0.1
            if f['bad']:
                f['abort'] = 0
        pargs += phase_files(d, p, fa, fb)
        fa_all.append(fa)
        fb_all.append(fb)
    pargs += ['speeds=' + ','.join(map(str, speeds)), 'an=1', 'stress=30,30,30,30,30,30', 'lpi=0,0,0,30,0,0',
              'txfmt=0,1,0,1,0,1', 'resignal=0,0,1,0,1,0', 'lockloss=1', 'lpdown=3', 'inconsist=2',
              'oa=@oa.txt', 'ra=@ra.txt', 'ta=@ta.txt', 'pr=@pr.txt', 'ps=@ps.txt']
    out, log, d = run(tag, {}, pargs, seed)
    print('   ', out.replace('\n', '\n    '))
    check_run(ck, out, d, speeds, fa_all, fb_all, True)
    pe = S.tb_values(out, 'PE')
    ck(sum(e['phy_ins'] for e in pe[-1:]) > 0 and pe[-1]['phy_del'] > 0 and pe[-1]['phy_lpi'] > 0,
       'PHY stress: %d idle words inserted, %d deleted, %d LPI words' % (pe[-1]['phy_ins'], pe[-1]['phy_del'],
                                                                         pe[-1]['phy_lpi']))
    lk = S.tb_values(out, 'LOCK')
    ph = S.tb_values(out, 'PH')
    ck(bool(lk) and len(ph) > 2 and 0 <= lk[0]['lost_after'] < 200 and lk[0]['link'] == 1 and lk[0]['dut_speed'] == 2
       and lk[0]['an_starts'] > ph[1]['an_starts'],
       'block lock lost (after %s cycles), AN restarted (DUT starts %s -> %s), relink at 1G after %s cycles'
       % (lk[0]['lost_after'] if lk else '?', ph[1]['an_starts'] if len(ph) > 1 else '?',
          lk[0]['an_starts'] if lk else '?', lk[0]['relink'] if lk else '?'))
    ck(len(ph) > 2 and ph[2]['an_starts'] - lk[0]['an_starts'] >= 2 if lk and len(ph) > 2 else False,
       'inconsistent exchange at 2.5G (acknowledged word with another speed): the DUT restarts (%s AN starts) and '
       'links at the offered speed' % ((ph[2]['an_starts'] - lk[0]['an_starts']) if lk and len(ph) > 2 else '?'))
    ld = S.tb_values(out, 'LPDOWN')
    ck(bool(ld) and ld[0]['an_cpl'] == 1 and ld[0]['lp_word'] & 0x8000 == 0 and ld[0]['usx_ok'] == 0 and
       ld[0]['link'] == 0 and ld[0]['lock'] == 1,
       'PHY copper link down (word 0x%04x): AN complete, stat_usx_link_ok 0, stat_link_up 0 with block lock'
       % (ld[0]['lp_word'] if ld else 0))
    return ck.done()


# ---------------------------------------------------------------- corrupt
def t_corrupt(seed, quick):
    ck = Check('usx_corrupt')
    rng = random.Random(seed + 600)
    speeds = [4, 4, 2, 5, 1]
    strict = [0, 1, 1, 0, 1]
    nfr = 30 if not quick else 12
    tag = 'corrupt_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_10g_usx', tag)
    os.makedirs(d, exist_ok=True)
    pargs, fa_all, fb_all = [], [], []
    for p, code in enumerate(speeds):
        n = nfr if code != 1 else 6
        fa = make_frames(rng, n, False)
        fb = make_frames(rng, n, False)
        for f in fb:
            f['bad'] = False
        pargs += phase_files(d, p, fa, fb)
        fa_all.append(fa)
        fb_all.append(fb)
    pargs += ['speeds=' + ','.join(map(str, speeds)), 'an=1', 'corrupt=50,50,50,50,50',
              'strict=' + ','.join(map(str, strict)), 'stress=20,20,20,20,20',
              'oa=@oa.txt', 'ra=@ra.txt', 'ta=@ta.txt', 'pr=@pr.txt', 'ps=@ps.txt']
    out, log, d = run(tag, {}, pargs, seed)
    print('   ', out.replace('\n', '\n    '))
    ps = read_cols(os.path.join(d, 'ps.txt'))
    exp_rep, i = [], 0
    for fb in fb_all:
        exp_rep.append(sum(1 for s in ps[i:i + len(fb)] if s[2] == 1))
        i += len(fb)
    check_run(ck, out, d, speeds, fa_all, fb_all, True, exp_rep=exp_rep, strict=strict)
    ck(all(x > 0 for x in exp_rep), 'corrupted frames per phase: %s (strict %s)' % (exp_rep, strict))
    return ck.done()


# ---------------------------------------------------------------- forced
def t_forced(seed, quick):
    ck = Check('usx_forced')
    rng = random.Random(seed + 700)
    speeds = [3, 4, 2, 1]
    tag = 'forced_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_10g_usx', tag)
    os.makedirs(d, exist_ok=True)
    pargs, fa_all, fb_all = [], [], []
    for p, code in enumerate(speeds):
        n = 10 if code != 1 else 4
        fa = make_frames(rng, n, False)
        fb = make_frames(rng, n, False)
        for f in fb:
            f['bad'] = False
        pargs += phase_files(d, p, fa, fb)
        fa_all.append(fa)
        fb_all.append(fb)
    pargs += ['speeds=' + ','.join(map(str, speeds)), 'an=0', 'stress=20,20,20,20',
              'oa=@oa.txt', 'ra=@ra.txt', 'ta=@ta.txt', 'pr=@pr.txt', 'ps=@ps.txt']
    out, log, d = run(tag, {}, pargs, seed)
    print('   ', out.replace('\n', '\n    '))
    c = check_run(ck, out, d, speeds, fa_all, fb_all, False)
    ck(c['an_s'] == 0 and c['an_d'] == 0, 'no auto-negotiation events with AN off')
    return ck.done()


# ---------------------------------------------------------------- antimer
def t_antimer(seed, quick):
    ck = Check('usx_antimer')
    rng = random.Random(seed + 800)
    tag = 'antimer_s%d' % seed
    d = os.path.join(S.BUILD, 'omac_10g_usx', tag)
    os.makedirs(d, exist_ok=True)
    fa = make_frames(rng, 6, False)
    fb = make_frames(rng, 6, False)
    for f in fb:
        f['bad'] = False
    pargs = phase_files(d, 0, fa, fb) + ['speeds=2', 'an=1', 'oa=@oa.txt', 'ra=@ra.txt', 'ta=@ta.txt',
                                         'pr=@pr.txt', 'ps=@ps.txt']
    out, log, d = run(tag, dict(LT=250000), pargs, seed)
    print('   ', out.replace('\n', '\n    '))
    check_run(ck, out, d, [2], [fa], [fb], True)
    ph = S.tb_values(out, 'PH')
    if ph:
        t = ph[0]['t']
        # restart + complete-acknowledge + idle-detect timers, plus block lock and the exchanges
        ck(3 * 250000 <= t <= 3 * 250000 + 40000, 'AN with the 1.6 ms link timer: link after %d cycles = %.2f ms '
           '(three link timers = 4.8 ms + lock and word exchanges)' % (t, t * 6.4e-6))
    return ck.done()


# ---------------------------------------------------------------- axil
def t_axil(seed, quick):
    ck = Check('usx_axil')
    srcs = S.ip_files('omac_10g') + [os.path.join(HERE, 'tb_usx_axil.sv')]
    out, log = S.xsim(os.path.join(S.BUILD, 'omac_10g_usx', 'b_axil'), 'tb_usx_axil', {}, srcs, [], 600, seed,
                      incdirs=[INC])
    lines = [l for l in log.splitlines() if l.startswith('TB_CHECK')]
    for l in lines:
        print('     ', l)
    r = S.tb_values(out, 'RESULT')
    ck(bool(r) and r[0]['errors'] == 0 and len(lines) >= 25, '%d register checks, %s errors'
       % (len(lines), r[0]['errors'] if r else '?'))
    return ck.done()


TESTS = {'axil': t_axil, 'speeds': t_speeds, 'corrupt': t_corrupt, 'forced': t_forced, 'antimer': t_antimer}


def main():
    args = sys.argv[1:]
    seed = 1
    if '--seed' in args:
        i = args.index('--seed')
        seed = int(args[i + 1])
        del args[i:i + 2]
    quick = '--quick' in args
    args = [a for a in args if a != '--quick']
    sel = args or list(TESTS)
    fails = 0
    for t in sel:
        print('== usx %s (seed %d)' % (t, seed), flush=True)
        fails += TESTS[t](seed, quick)
    print('OMAC_10G_USX TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
