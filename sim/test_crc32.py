#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# test_crc32.py - omac_crc32 against Python's zlib.crc32 (an independent
# implementation of the Ethernet CRC): random frames of 0..2000 bytes (every
# last-word size), the check value of "123456789" (0xCBF43926, the published
# CRC-32 check), and the frame+FCS residue 0xDEBB20E3, at BYTES 8 and 32.
# Usage: test_crc32.py [nframes] [seed]
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import os
import random
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import simlib as S  # noqa: E402


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    seed = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    rng = random.Random(seed)
    frames = [b'123456789', b'\x00', b'\xff' * 7]
    for i in range(n):
        ln = rng.choice([rng.randint(1, 80), rng.randint(1, 2000)])
        frames.append(bytes(rng.getrandbits(8) for _ in range(ln)))
    assert zlib.crc32(b'123456789') == 0xCBF43926
    fails = 0
    for nb in (8, 32):
        d = os.path.join(S.BUILD, 'crc32_b%d' % nb)
        os.makedirs(d, exist_ok=True)
        fin, fout = os.path.join(d, 'in.txt'), os.path.join(d, 'out.txt')
        with open(fin, 'w') as f:
            for fr in frames:
                f.write('%d %s\n' % (len(fr), fr.hex()))
        out, log = S.xsim(d, 'tb_crc32', {'BYTES': nb}, S.common('omac_crc32.sv') + [os.path.join(HERE, 'tb_crc32.sv')],
                          ['in=' + fin, 'out=' + fout])
        print('   ', out.replace('\n', ' | '))
        if 'TB_DONE' not in out:
            print('simulation failed (BYTES=%d)' % nb)
            fails += 1
            continue
        res = [l.split() for l in open(fout) if l.strip()]
        bad = 0
        for fr, (fcs, rsd) in zip(frames, res):
            if int(fcs, 16) != zlib.crc32(fr) or int(rsd, 16) != 0xDEBB20E3:
                bad += 1
        bad += abs(len(res) - len(frames))
        print('BYTES=%d: %d frames, %d mismatches (check value %s)' % (nb, len(res), bad, res[0][0]))
        fails += bad
    print('CRC32 TEST %s (%d failures)' % ('PASS' if fails == 0 else 'FAIL', fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
