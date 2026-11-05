#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
#
# omac_ref.py - Python reference model for the opsero-ethernet-mac tests, written
# independently of the RTL from IEEE 802.3 clauses 46/49/81/82 and annex 31B:
#   * Ethernet FCS with zlib.crc32
#   * a bit-serial 64B/66B descrambler (x^58 + x^39 + 1)
#   * a 66-bit block decoder (figure 49-7) and an XGMII frame parser that checks
#     preamble/SFD, start lane (0 or 4), FCS, and measures the inter-packet gaps
#   * 40GBASE-R (clause 82): alignment marker table, BIP3, a four-lane decoder
#     that finds the markers on lanes in any order and skew, checks their period
#     and BIP, deskews, reorders, removes them, descrambles the aggregate stream,
#     decodes with the clause 82 block subset and parses XLGMII frames (start on
#     8-byte columns only)
#   * PAUSE frame decoding, frame-file I/O for the testbenches
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

import zlib

IDLE, START, TERM, ERROR, SEQ = 0x07, 0xFB, 0xFD, 0xFE, 0x9C
T_TYPES = {0x87: 0, 0x99: 1, 0xAA: 2, 0xB4: 3, 0xCC: 4, 0xD2: 5, 0xE1: 6, 0xFF: 7}
CODES = {0x00: IDLE, 0x06: 0x06, 0x1E: ERROR}


def fcs(frame):
    return zlib.crc32(frame).to_bytes(4, 'little')


class Descrambler:
    """Bit-serial: out = in ^ s[38] ^ s[57], the shift register holds received bits."""

    def __init__(self):
        self.s = [0] * 58

    def word(self, w):
        o = 0
        for i in range(64):
            b = (w >> i) & 1
            o |= (b ^ self.s[38] ^ self.s[57]) << i
            self.s = [b] + self.s[:57]
        return o


def _code(p, pos):
    return CODES.get((p >> pos) & 0x7F, None)


def decode_block(hdr, p):
    """66-bit block -> list of 8 (is_ctrl, byte) lanes, or None for an invalid block.
    hdr in IEEE order (bit 0 first): data = 0b10, control = 0b01."""
    if hdr == 0b10:
        return [(0, (p >> (8 * i)) & 0xFF) for i in range(8)]
    if hdr != 0b01:
        return None
    bt = p & 0xFF
    byte = lambda i: (p >> (8 * i)) & 0xFF   # noqa: E731  byte i of the payload (byte 0 = type)
    ostr = lambda o: SEQ if o == 0 else (0x5C if o == 0xF else None)   # noqa: E731
    lanes = []
    if bt == 0x1E:
        lanes = [(1, _code(p, 8 + 7 * i)) for i in range(8)]
    elif bt == 0x78:
        lanes = [(1, START)] + [(0, byte(i)) for i in range(1, 8)]
    elif bt in (0x33, 0x2D):
        lanes = [(1, _code(p, 8 + 7 * i)) for i in range(4)]
        lanes.append((1, START) if bt == 0x33 else (1, ostr((p >> 36) & 0xF)))
        lanes += [(0, byte(i)) for i in range(5, 8)]
    elif bt in (0x66, 0x55):
        lanes = [(1, ostr((p >> 32) & 0xF))] + [(0, byte(i)) for i in range(1, 4)]
        lanes.append((1, START) if bt == 0x66 else (1, ostr((p >> 36) & 0xF)))
        lanes += [(0, byte(i)) for i in range(5, 8)]
    elif bt == 0x4B:
        lanes = [(1, ostr((p >> 32) & 0xF))] + [(0, byte(i)) for i in range(1, 4)]
        lanes += [(1, _code(p, 36 + 7 * i)) for i in range(4)]
    elif bt in T_TYPES:
        k = T_TYPES[bt]
        lanes = [(0, byte(i + 1)) for i in range(k)] + [(1, TERM)]
        lanes += [(1, _code(p, 64 - 7 * (8 - i))) for i in range(k + 1, 8)]
    else:
        return None
    if any(v is None for _, v in lanes):
        return None
    return lanes


def parse_capture(path):
    """Decode a TX capture ("hdr data" per line, IEEE bit order). Returns
    (frames, info): frames = list of (bytes without FCS, fcs_ok, start_lane),
    info = dict(gaps=[IPG bytes from /T/ inclusive to /S/], invalid=n, fault_cols=n,
    sof_line=[capture line of each frame's /S/ block; line 0 only synchronises the descrambler])."""
    ds = Descrambler()
    lanes = []
    invalid = 0
    first = True
    for line in open(path):
        h, d = line.split()
        p = ds.word(int(d, 16))
        if first:          # the descrambler needs one block to synchronise
            first = False
            continue
        blk = decode_block(int(h), p)
        if blk is None:
            invalid += 1
            blk = [(1, ERROR)] * 8
        lanes.extend(blk)
    frames, gaps, sof_line = [], [], []
    i, n = 0, len(lanes)
    last_t = None
    fault_cols = 0
    while i < n:
        c, v = lanes[i]
        if c and v == SEQ and i % 4 == 0:
            fault_cols += 1
        if c and v == START:
            if last_t is not None:
                gaps.append(i - last_t)
            start_lane = i % 8
            pre = [lanes[i + k] for k in range(1, 8)]
            good_pre = all(x == (0, 0x55) for x in pre[:6]) and pre[6] == (0, 0xD5)
            j = i + 8
            data = bytearray()
            while j < n and lanes[j][0] == 0:
                data.append(lanes[j][1])
                j += 1
            if j >= n:
                break
            term = lanes[j] == (1, TERM)
            ok = good_pre and term and len(data) >= 4 and fcs(bytes(data[:-4])) == bytes(data[-4:])
            frames.append((bytes(data[:-4]), ok, start_lane))
            sof_line.append(1 + i // 8)
            last_t = j
            i = j + 1
            continue
        i += 1
    return frames, dict(gaps=gaps, invalid=invalid, fault_cols=fault_cols, sof_line=sof_line)


# ---------------------------------------------------------------- 40GBASE-R
# IEEE 802.3 table 82-3, 40GBASE-R: M0, M1, M2 of PCS lanes 0..3 (M4..M6 = ~M0..~M2)
AM40 = [(0x90, 0x76, 0x47), (0xF0, 0xC4, 0xE6), (0xC5, 0x65, 0x9B), (0xA2, 0x79, 0x3D)]


def am_payload(lane, bip3):
    """64-bit payload of the AM of `lane` (byte 0 = M0, transmitted first)."""
    m0, m1, m2 = AM40[lane]
    by = [m0, m1, m2, bip3, m0 ^ 0xFF, m1 ^ 0xFF, m2 ^ 0xFF, bip3 ^ 0xFF]
    return sum(b << (8 * i) for i, b in enumerate(by))


def am_lane(hdr, p):
    """PCS lane number if the block is an alignment marker (BIP bytes ignored), else None."""
    if hdr != 0b01:
        return None
    by = [(p >> (8 * i)) & 0xFF for i in range(8)]
    for lane, (m0, m1, m2) in enumerate(AM40):
        if by[0:3] == [m0, m1, m2] and by[4:7] == [m0 ^ 0xFF, m1 ^ 0xFF, m2 ^ 0xFF]:
            return lane
    return None


def bip3_block(hdr, p):
    """BIP3 contribution of one 66-bit block, from table 82-4 written out bit by bit:
    66-bit block bit k (k = 0, 1: sync header, k = 2 + j: payload bit j) goes to
    BIP3 bit (k - 2) mod 8, except header bits 0 and 1, which go to BIP3 bits 3 and 4."""
    blk = (p << 2) | hdr                    # bit 0 = first on the wire
    table = {0: [2, 10, 18, 26, 34, 42, 50, 58], 1: [3, 11, 19, 27, 35, 43, 51, 59],
             2: [4, 12, 20, 28, 36, 44, 52, 60], 3: [0, 5, 13, 21, 29, 37, 45, 53, 61],
             4: [1, 6, 14, 22, 30, 38, 46, 54, 62], 5: [7, 15, 23, 31, 39, 47, 55, 63],
             6: [8, 16, 24, 32, 40, 48, 56, 64], 7: [9, 17, 25, 33, 41, 49, 57, 65]}
    r = 0
    for bit, ks in table.items():
        v = 0
        for k in ks:
            v ^= (blk >> k) & 1
        r |= v << bit
    return r


def decode_block_r4(hdr, p):
    """Clause 82: the clause 49 decoder restricted to 0x1E, 0x78, 0x4B and the /T/ types."""
    if hdr == 0b01 and (p & 0xFF) in (0x2D, 0x33, 0x66, 0x55):
        return None
    return decode_block(hdr, p)


def parse_capture_40g(path, am_period=16384):
    """Decode a four-lane capture ("h0 d0 h1 d1 h2 d2 h3 d3" per line, physical lane order,
    lanes possibly permuted and skewed). Returns (frames, info): frames = list of
    (bytes without FCS, fcs_ok, start_lane), info = dict(gaps, invalid, bip_err, ams,
    lane_ids, skew, spacing_err, align_err)."""
    lanes = [[], [], [], []]
    for line in open(path):
        f = line.split()
        if len(f) < 8:
            continue
        for q in range(4):
            lanes[q].append((int(f[2 * q]), int(f[2 * q + 1], 16)))
    info = dict(gaps=[], invalid=0, bip_err=0, ams=0, lane_ids=[None] * 4, skew=None, spacing_err=0,
                align_err=0)
    pos, ids = [], []
    for q in range(4):
        pq, iq = [], set()
        for i, (h, d) in enumerate(lanes[q]):
            ln = am_lane(h, d)
            if ln is not None:
                pq.append(i)
                iq.add(ln)
        if len(iq) != 1 or len(pq) < 1:
            info['lane_ids'][q] = sorted(iq)
            return [], info
        info['lane_ids'][q] = iq.pop()
        info['ams'] += len(pq)
        info['spacing_err'] += sum(1 for a, b in zip(pq, pq[1:]) if b - a != am_period)
        # BIP3 / BIP7 of every marker after the first, over the lane from the previous marker
        for a, b in zip(pq, pq[1:]):
            x = 0
            for h, d in lanes[q][a:b]:
                x ^= bip3_block(h, d)
            b3 = (lanes[q][b][1] >> 24) & 0xFF
            b7 = (lanes[q][b][1] >> 56) & 0xFF
            if b3 != x or b7 != (x ^ 0xFF):
                info['bip_err'] += 1
        pos.append(pq)
    if sorted(info['lane_ids']) != [0, 1, 2, 3]:
        return [], info
    # deskew: per lane the marker nearest to the latest first marker
    ref = max(p[0] for p in pos)
    start = [min(p, key=lambda x: abs(x - ref)) for p in pos]
    info['skew'] = max(start) - min(start)
    nblk = min(len(lanes[q]) - start[q] for q in range(4))
    q_of = {info['lane_ids'][q]: q for q in range(4)}
    words = []
    for n in range(-min(start), nblk):      # from the start of the capture (before the first marker too)
        blks = [lanes[q_of[L]][start[q_of[L]] + n] for L in range(4)]
        is_am = [am_lane(h, d) is not None for h, d in blks]
        if any(is_am):
            if not all(is_am) or n % am_period != 0:
                info['align_err'] += 1
            continue
        words.extend(blks)
    # descramble the aggregate stream, decode, parse XLGMII frames
    ds = Descrambler()
    stream = []
    for k, (h, d) in enumerate(words):
        p = ds.word(d)
        if k == 0:
            continue
        blk = decode_block_r4(h, p)
        if blk is None:
            info['invalid'] += 1
            blk = [(1, ERROR)] * 8
        stream.extend(blk)
    frames, gaps = [], []
    i, n = 0, len(stream)
    last_t = None
    while i < n:
        c, v = stream[i]
        if c and v == START:
            if last_t is not None:
                gaps.append(i - last_t)
            start_lane = i % 8
            pre = [stream[i + k] for k in range(1, 8) if i + k < n]
            good_pre = len(pre) == 7 and all(x == (0, 0x55) for x in pre[:6]) and pre[6] == (0, 0xD5)
            j = i + 8
            data = bytearray()
            while j < n and stream[j][0] == 0:
                data.append(stream[j][1])
                j += 1
            if j >= n:
                break
            term = stream[j] == (1, TERM)
            ok = good_pre and term and len(data) >= 4 and fcs(bytes(data[:-4])) == bytes(data[-4:])
            frames.append((bytes(data[:-4]), ok, start_lane))
            last_t = j
            i = j + 1
            continue
        i += 1
    info['gaps'] = gaps
    return frames, info


def pause_fields(fr):
    """(da, sa, ethertype, opcode, pause_time) of a frame (bytes without FCS)."""
    return (fr[0:6], fr[6:12], int.from_bytes(fr[12:14], 'big'), int.from_bytes(fr[14:16], 'big'),
            int.from_bytes(fr[16:18], 'big'))


def write_frames(path, frames):
    """frames: list of dict(b=bytes, gap=int, abort=-1, under=-1)."""
    with open(path, 'w') as f:
        for fr in frames:
            f.write('%d %d %d %d %s\n' % (len(fr['b']), fr.get('gap', 0), fr.get('abort', -1),
                                          fr.get('under', -1), fr['b'].hex()))


def read_rx(path):
    out = []
    for line in open(path):
        parts = line.split()
        if not parts:
            continue
        out.append((int(parts[0]), bytes.fromhex(parts[1]) if len(parts) > 1 else b''))
    return out


def selftest():
    # an idle block from a zero scrambler state (hand-computed, see tb_pcs_units)
    ds = Descrambler()
    assert ds.word(0x78000F000000001E) == 0x1E
    assert decode_block(0b01, 0x1E) == [(1, IDLE)] * 8
    assert decode_block(0b01, 0x00000000332211B4) == [(0, 0x11), (0, 0x22), (0, 0x33), (1, TERM)] + [(1, IDLE)] * 4
    assert zlib.crc32(b'123456789') == 0xCBF43926
    # 40GBASE-R: an AM's own BIP3 contribution is 0x08 (bytes cancel, header bit 0 -> BIP bit 3)
    assert bip3_block(0b01, am_payload(0, 0x5A)) == 0x08
    assert am_lane(0b01, am_payload(3, 0x00)) == 3 and am_lane(0b10, am_payload(3, 0)) is None
    assert am_payload(0, 0x1E) == 0xE1B8896F1E477690


if __name__ == '__main__':
    selftest()
    print('omac_ref selftest PASS')
