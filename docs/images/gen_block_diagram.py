#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""
Generate the diagrams for the opsero-ethernet-mac (omac) docs.

    omac-10g-block.png   omac_10g: transmit path (arbiter, pad, FCS, XGMII
                         columns, RS, PCS TX), PAUSE, receive path (PCS RX,
                         RS fault detection, MAC RX), the RX clock crossing
                         and the clock domains (ip/omac_10g/rtl, common/)
    omac-40g-block.png   omac_40g: transmit path (column packer, PCS TX with
                         lane distribution, alignment markers + BIP3), the four
                         per-lane receive front ends in their recovered clocks,
                         deskew / reorder / decode in rclk, the MAC RX and its
                         two clock-crossing banks (ip/omac_40g/rtl, common/)
    omac-gth-block.png   the UltraScale+ GTH wrappers omac_gt_usp_gth (one lane)
                         and omac_gt_usp_gth_x4 (four lanes) between an omac IP
                         and the transceivers: reference clock, free-running
                         clock and reset, user clocks, GT-side signals
                         (gt/omac_gt_usp_gth)

Conventions shared with the other Opsero diagrams (rocelet/docs/images and
qsfp28-fmc-rocelet/docs/source/images gen_block_diagram.py): same palette,
helpers and fonts, left-to-right layout with the user side on the left and the
transceiver on the right; lavender = logic of this repository, cream = AMD
transceiver / IP used as it is, grey = the user's logic; pale green arrows =
AXI4-Stream and 66-bit block streams, blue thin = control / status, orange =
clocks, thin grey = sideband (PAUSE, events). Dashed frames = clock domains.

The PNGs are written next to this script (i.e. into docs/images/).

Usage (from anywhere):
    python3 docs/images/gen_block_diagram.py
"""

import os
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Polygon, FancyArrowPatch, Circle
from matplotlib.lines import Line2D

# ---- palette (shared with the other Opsero reference-design block diagrams) --
C_PS_FILL      = "#D9D9D9"; C_PS_EDGE      = "#7F7F7F"   # processor / DDR column
C_FAB_FILL     = "#F2F2F2"; C_FAB_EDGE     = "#BFBFBF"   # FPGA fabric container
C_MAC_FILL     = "#E8E8F2"; C_MAC_EDGE     = "#8C8CC0"   # soft logic (lavender)
C_GT_FILL      = "#F3EFE2"; C_GT_EDGE      = "#BFB585"   # hard blocks: PCIe, GT (cream)
C_FMC_FILL     = "#DCE6F2"; C_FMC_EDGE     = "#9DB7D4"   # external FMC (blue-grey)
C_SLOT_FILL    = "#FFFFFF"                                # M.2 slots (white on FMC)
C_CLK_FILL     = "#FDE9D9"; C_CLK_EDGE     = "#E0B090"   # clocking (peach)
C_CTRL_FILL    = "#ECECEC"; C_CTRL_EDGE    = "#BFBFBF"   # notes / control caption
C_AXARR_FILL   = "#EDF3D4"; C_AXARR_EDGE   = "#A6B85A"   # DMA arrows (pale green)
C_LINKARR_FILL = "#DAE8F5"; C_LINKARR_EDGE = "#6F9FCF"   # host access + link arrows
C_REFCLK_LINE  = "#C8823C"                                # clocks (orange)
C_THIN         = "#8C8C8C"                                # sideband / interrupts
C_MUTED        = "#6E6E6E"
TXT = "#1A1A1A"
# recorder additions (same family of tints)
C_USER_FILL    = "#E2F0E4"; C_USER_EDGE    = "#7FB08A"   # user insertion points
C_DATA_LINE    = "#6E8F1E"                                # zero-copy data path (dark green)
C_CTRL_LINE    = "#4A7DB5"                                # control path (dark blue)
C_WARN         = "#A0522D"                                # contract annotations


def box(ax, x, y, w, h, fc, ec, label, fs=10, lw=1.2, weight="normal",
        txtcolor=None, ls="-", z=2):
    ax.add_patch(plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=lw, ls=ls,
                               zorder=z))
    if label:
        ax.text(x + w / 2, y + h / 2, label, ha="center", va="center",
                fontsize=fs, color=txtcolor or TXT, weight=weight,
                zorder=z + 1, linespacing=1.25)


def titled_box(ax, x, y, w, h, fc, ec, title, body, title_fs=9.5, body_fs=7.6,
               lw=1.2, txtcolor=None, title_dy=2.4, ls="-", z=2):
    """A box() with a bold title line at the top and a smaller body below it."""
    box(ax, x, y, w, h, fc, ec, "", lw=lw, ls=ls, z=z)
    cx = x + w / 2
    ax.text(cx, y + h - title_dy, title, ha="center", va="center",
            fontsize=title_fs, weight="bold", color=txtcolor or TXT, zorder=z + 1,
            linespacing=1.15)
    ax.text(cx, y + (h - title_dy * 1.9) / 2, body, ha="center", va="center",
            fontsize=body_fs, color=txtcolor or TXT, zorder=z + 1, linespacing=1.3)


def harrow(ax, x0, x1, yc, label, fc, ec, double=False, bh=1.1, hh=2.0,
           hl=1.6, fs=7.4, lw=1.0, lab_dy=2.9, lab_color=None, z=2):
    """Horizontal block arrow from x0 to x1 (head at x1; both ends if double)."""
    if double:
        lo, hi = min(x0, x1), max(x0, x1)
        pts = [(lo, yc), (lo + hl, yc + hh), (lo + hl, yc + bh),
               (hi - hl, yc + bh), (hi - hl, yc + hh), (hi, yc),
               (hi - hl, yc - hh), (hi - hl, yc - bh),
               (lo + hl, yc - bh), (lo + hl, yc - hh)]
    else:
        s = 1.0 if x1 >= x0 else -1.0
        neck = x1 - s * hl
        pts = [(x0, yc + bh), (neck, yc + bh), (neck, yc + hh),
               (x1, yc), (neck, yc - hh), (neck, yc - bh), (x0, yc - bh)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))
    if label:
        ax.text((x0 + x1) / 2, yc + lab_dy, label, ha="center", va="center",
                fontsize=fs, color=lab_color or TXT, zorder=z + 1, linespacing=1.15)


def vblock(ax, xc, y0, y1, fc, ec, bw=1.0, hw=1.9, hl=1.5, lw=1.0, double=True,
           z=2):
    """Vertical block arrow from y0 to y1 (head at y1; both ends if double)."""
    if double:
        lo, hi = min(y0, y1), max(y0, y1)
        pts = [(xc, lo), (xc + hw, lo + hl), (xc + bw, lo + hl),
               (xc + bw, hi - hl), (xc + hw, hi - hl), (xc, hi),
               (xc - hw, hi - hl), (xc - bw, hi - hl),
               (xc - bw, lo + hl), (xc - hw, lo + hl)]
    else:
        s = 1.0 if y1 >= y0 else -1.0
        neck = y1 - s * hl
        pts = [(xc + bw, y0), (xc + bw, neck), (xc + hw, neck), (xc, y1),
               (xc - hw, neck), (xc - bw, neck), (xc - bw, y0)]
    ax.add_patch(Polygon(pts, closed=True, fc=fc, ec=ec, lw=lw, zorder=z))


def route(ax, pts, color, lw=1.3, ls="-", z=3, ms=9):
    """Thin elbow arrow through the points in pts (head at the last point)."""
    xs, ys = zip(*pts[:-1])
    ax.add_line(Line2D(list(xs) + [pts[-2][0]], list(ys) + [pts[-2][1]],
                       color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt", solid_joinstyle="miter"))
    ax.add_patch(FancyArrowPatch(pts[-2], pts[-1], arrowstyle="-|>",
                                 mutation_scale=ms, lw=lw, color=color,
                                 zorder=z, shrinkA=0, shrinkB=0))


def line(ax, pts, color, lw=1.1, ls="-", z=3):
    xs, ys = zip(*pts)
    ax.add_line(Line2D(xs, ys, color=color, lw=lw, ls=ls, zorder=z,
                       solid_capstyle="butt"))


def clk_tag(ax, x, y, text, fs=7.2, ha="center"):
    """An orange clock-domain label."""
    ax.text(x, y, text, ha=ha, va="center", fontsize=fs, color=C_REFCLK_LINE,
            weight="bold", zorder=6, linespacing=1.15)


def marker(ax, x, y, n, color=C_CTRL_LINE, r=1.25, fs=7.5):
    """A numbered circle (step marker)."""
    ax.add_patch(Circle((x, y), r, fc="white", ec=color, lw=1.3, zorder=7))
    ax.text(x, y, str(n), ha="center", va="center", fontsize=fs, weight="bold",
            color=color, zorder=8)


def new_fig(w=17.0, h=10.6, xmax=170, ymax=106):
    fig, ax = plt.subplots(figsize=(w, h), dpi=120)
    ax.set_xlim(0, xmax)
    ax.set_ylim(0, ymax)
    ax.axis("off")
    return fig, ax


def save(fig, name):
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    fig.savefig(out, bbox_inches="tight", pad_inches=0.15, facecolor="white")
    plt.close(fig)
    print("wrote", out)



def legend(ax, x, y, items, fs=7.2, dy=3.6):
    """Arrow-colour key: items = [(fill, edge, text), ...]; a None fill draws a line."""
    for i, (fc, ec, text) in enumerate(items):
        yy = y - i * dy
        if fc is None:
            line(ax, [(x, yy), (x + 6.0, yy)], ec, lw=1.6)
        else:
            harrow(ax, x, x + 6.0, yy, "", fc, ec, bh=0.8, hh=1.5, hl=1.2)
        ax.text(x + 7.5, yy, text, ha="left", va="center", fontsize=fs, color=TXT)


def dashed_group(ax, x, y, w, h, label, ec=C_MAC_EDGE, fs=7.4, lab_dx=1.2,
                 lab_dy=-1.6, z=1.5, fc="none"):
    """A dashed frame around a group of blocks, its label at the top left."""
    ax.add_patch(plt.Rectangle((x, y), w, h, fc=fc, ec=ec, lw=1.1, ls=(0, (4, 2)),
                               zorder=z))
    if label:
        ax.text(x + lab_dx, y + h + lab_dy, label, ha="left", va="center",
                fontsize=fs, weight="bold", color=ec, zorder=z + 1)


C_USERLOGIC_FILL = "#ECECEC"; C_USERLOGIC_EDGE = "#9A9A9A"   # the user's logic (grey)
DASH = (0, (4, 2))


def ptext(ax, x, y, text, ha="center", fs=6.8, color=TXT, weight="normal"):
    ax.text(x, y, text, ha=ha, va="center", fontsize=fs, color=color, weight=weight,
            zorder=6, linespacing=1.15)


def notes(ax, x, y, w, h, title, body):
    titled_box(ax, x, y, w, h, C_CTRL_FILL, C_CTRL_EDGE, title, body, title_fs=7.2,
               body_fs=6.8, title_dy=2.2)


# -----------------------------------------------------------------------------
# 1. omac_10g.
#
# ip/omac_10g/rtl/omac_10g.sv (top: resets, crossings, RS transmit mux, PAUSE,
# watchdog), omac_10g_mac_tx.sv, omac_10g_pcs_tx.sv, omac_10g_pcs_rx.sv,
# omac_10g_mac_rx.sv; common/ omac_rs_fault, omac_async_fifo, omac_pause.
# -----------------------------------------------------------------------------
def draw_10g():
    fig, ax = new_fig(20.0, 10.6, 190, 100)
    # user logic and transceiver
    titled_box(ax, 2.0, 14.0, 13.0, 66.0, C_USERLOGIC_FILL, C_USERLOGIC_EDGE, "user logic",
               "all user-side\nports on clk:\n\ns_axis_tx_*\nm_axis_rx_*\nctl_*\nstat_*\nev_*",
               title_fs=8.6, body_fs=7.0, title_dy=2.4)
    titled_box(ax, 172.0, 14.0, 16.0, 66.0, C_GT_FILL, C_GT_EDGE, "transceiver",
               "one GTH / GTY\nchannel in 64B/66B\nasync gearbox mode\n\n"
               "(omac_gt_usp_gth\non UltraScale+ GTH)\n\n10.3125 Gb/s\n(25G: 25.78125)",
               title_fs=8.6, body_fs=6.8, title_dy=2.4)
    # IP container
    c_x0, c_x1 = 19.0, 168.0
    ax.add_patch(plt.Rectangle((c_x0, 6.0), c_x1 - c_x0, 80.0, fc="#FAFAFD", ec=C_MAC_EDGE,
                               lw=1.4, zorder=1))
    ax.text(c_x0 + 1.5, 83.2, "omac_10g  (ip/omac_10g/rtl/omac_10g.sv)", ha="left",
            va="center", fontsize=9.6, weight="bold", color=TXT)
    clk_tag(ax, c_x1 - 1.5, 83.2, "clk = GT TXUSRCLK2: 156.25 MHz (25G: 390.625 MHz)", ha="right")

    # ---- transmit path (clk) ----
    ty0, th = 62.0, 14.0
    yc = ty0 + th / 2
    tx = [
        (24.0, 17.0, "arbiter", "PAUSE frame first,\nthen user frames\n(ctl_tx_enable)"),
        (45.0, 13.0, "pad", "to 60 bytes,\nbytes beyond\ntkeep zeroed"),
        (62.0, 13.0, "FCS", "CRC-32\nappended"),
        (79.0, 22.0, "XGMII columns", "preamble + SFD, /S/ in\nlane 0 or 4, /T/, IPG\nwith deficit idle count,\n"
                                      "underflow / abort = /E/"),
        (105.0, 16.0, "RS TX", "Local / Remote\nFault or idle\ncolumns (fault\nstate, ctl_tx_fault)"),
        (125.0, 20.0, "PCS TX", "enc66 (fig. 49-7)\n+ scrambler,\n2 cycles"),
    ]
    for (x, w, t, b) in tx:
        titled_box(ax, x, ty0, w, th, C_MAC_FILL, C_MAC_EDGE, t, b, title_fs=8.0, body_fs=6.7,
                   title_dy=1.9, z=3)
    for (x, w, _, _), (x2, _, _, _) in zip(tx[:-1], tx[1:]):
        harrow(ax, x + w, x2, yc, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=0.9)
    harrow(ax, 15.0, 24.0, yc, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.1)
    ptext(ax, 19.5, yc + 3.3, "s_axis_tx\n64 b")
    harrow(ax, 145.0, 172.0, yc, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.1)
    ptext(ax, 158.5, yc + 3.6, "gt_tx_hdr[1:0]\ngt_tx_data[63:0]")

    # ---- PAUSE, status, watchdog (clk) ----
    titled_box(ax, 24.0, 40.0, 30.0, 15.0, C_MAC_FILL, C_MAC_EDGE, "omac_pause  (common/)",
               "TX: XOFF on ctl_tx_pause_send, repeat\nevery ctl_tx_pause_refresh, XON at the end\n"
               "RX: pause timer in bit times (64 per\nclock) → stat_rx_pause_req (level)",
               title_fs=7.8, body_fs=6.5, title_dy=1.9, z=3)
    vblock(ax, 32.5, 55.0, ty0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=1.0, double=False)
    ptext(ax, 34.5, 58.5, "PAUSE frame", ha="left", fs=6.5)
    route(ax, [(24.0, 44.0), (15.0, 44.0)], C_THIN, lw=1.2, ms=7)
    ptext(ax, 19.5, 47.2, "stat_rx_\npause_req", fs=6.0, color=C_MUTED)
    titled_box(ax, 60.0, 40.0, 36.0, 15.0, C_CTRL_FILL, C_CTRL_EDGE, "status and events",
               "stat_*: 2-flop synchronisers into clk\nev_*: gray-coded event counters\n"
               "(no pulse lost across the crossing)\nreset synchroniser for the RX side",
               title_fs=7.8, body_fs=6.5, title_dy=1.9, z=3)
    route(ax, [(60.0, 49.0), (58.0, 49.0), (58.0, 37.0), (15.0, 37.0)], C_CTRL_LINE, lw=1.2,
          ms=7)
    ptext(ax, 19.5, 39.2, "stat_*, ev_*", fs=6.0, color=C_CTRL_LINE)
    titled_box(ax, 125.0, 40.0, 20.0, 15.0, C_MAC_FILL, C_MAC_EDGE, "watchdog",
               "no block lock for\na while: restart\nthe GT RX datapath\n(gt_rx_reset_req)",
               title_fs=7.8, body_fs=6.5, title_dy=1.9, z=3)
    route(ax, [(145.0, 47.5), (172.0, 47.5)], C_CTRL_LINE, lw=1.2, ms=7)

    # ---- receive path (gt_rx_clk) ----
    dashed_group(ax, 70.0, 9.0, 96.0, 25.0, "gt_rx_clk  (recovered RX user clock)",
                 ec=C_REFCLK_LINE, fs=7.2)
    ry0, rh = 11.0, 16.0
    ryc = ry0 + rh / 2
    rx = [
        (52.0, 22.0, "async FIFO", "74 b x 32 LUTRAM,\ngray pointers:\ngt_rx_clk → clk", C_CTRL_FILL, C_CTRL_EDGE),
        (78.0, 26.0, "MAC RX", "start + SFD (lane 0 / 4),\n4-byte realignment,\nFCS check + strip,\n"
                               "MIN / MAX length,\n0x8808 filter, PAUSE decode", C_MAC_FILL, C_MAC_EDGE),
        (108.0, 21.0, "RS fault", "link fault state\n(fig. 46-11): 4 fault\nsequences in 128\ncolumns set it", C_MAC_FILL, C_MAC_EDGE),
        (133.0, 31.0, "PCS RX", "block lock + slip, BER monitor,\ndescrambler, dec66,\nreceive state machine\n"
                                "(fig. 49-17, with look-ahead)", C_MAC_FILL, C_MAC_EDGE),
    ]
    for (x, w, t, b, fc, ec) in rx:
        titled_box(ax, x, ry0, w, rh, fc, ec, t, b, title_fs=8.0, body_fs=6.6, title_dy=1.9, z=3)
    for (x, w, *_), (x2, w2, *_) in zip(rx[:-1], rx[1:]):
        harrow(ax, x2, x + w, ryc, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=0.9)
    harrow(ax, 172.0, 164.0, ryc, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.1)
    ptext(ax, 168.0, ryc + 5.0, "gt_rx_hdr\ngt_rx_data\ngt_rx_valid", fs=6.2)
    route(ax, [(160.0, ry0), (160.0, 8.0), (174.0, 8.0), (174.0, 14.0)], C_CTRL_LINE, lw=1.1,
          ms=6)
    ptext(ax, 166.5, 6.6, "gt_rx_slip", fs=6.2, color=C_CTRL_LINE)
    harrow(ax, 52.0, 15.0, ryc, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.1)
    ptext(ax, 33.0, ryc + 3.6, "m_axis_rx 64 b (no tready),\ntuser = bad frame", fs=6.4)
    # received pause_time -> omac_pause (toggle CDC)
    route(ax, [(84.0, ry0 + rh), (84.0, 31.0), (40.0, 31.0), (40.0, 40.0)], C_THIN, lw=1.2,
          ms=7)
    ptext(ax, 41.5, 32.8, "received pause_time (toggle CDC)", ha="left", fs=6.3, color=C_MUTED)

    ax.text(95.0, 95.0, "omac_10g  —  10GBASE-R (25GBASE-R with SPEED = 25) MAC + PCS",
            ha="center", va="center", fontsize=13.0, weight="bold", color=TXT)
    ax.text(95.0, 90.6, "lavender: omac logic   grey: clock-domain crossings and synchronisers   "
            "cream: the transceiver   pale green: frames / 66-bit blocks   blue: control and status   "
            "dashed orange frame: the recovered RX clock domain", ha="center", va="center",
            fontsize=7.0, color=C_MUTED)
    save(fig, "omac-10g-block.png")


# -----------------------------------------------------------------------------
# 2. omac_40g.
#
# ip/omac_40g/rtl/omac_40g.sv (top: resets, lane instances + FIFOs, crossings, RS
# transmit mux, PAUSE, watchdog), omac_40g_mac_tx.sv, omac_40g_pcs_tx.sv,
# omac_40g_lane_rx.sv, omac_40g_pcs_rx.sv, omac_40g_mac_rx.sv; common/.
# -----------------------------------------------------------------------------
def draw_40g():
    fig, ax = new_fig(21.0, 12.6, 200, 120)
    titled_box(ax, 2.0, 12.0, 12.0, 88.0, C_USERLOGIC_FILL, C_USERLOGIC_EDGE, "user logic",
               "all user-side\nports on clk:\n\ns_axis_tx_*\nm_axis_rx_*\nctl_*\nstat_*\nev_*",
               title_fs=8.4, body_fs=6.9, title_dy=2.4)
    titled_box(ax, 182.0, 12.0, 16.0, 88.0, C_GT_FILL, C_GT_EDGE, "transceivers",
               "four GTH / GTY\nchannels, 64B/66B\nasync gearbox\n\n(omac_gt_usp_gth_x4\non UltraScale+ GTH)\n\n"
               "4 x 10.3125 Gb/s\n\none TX user clock,\none recovered RX\nclock per lane",
               title_fs=8.4, body_fs=6.7, title_dy=2.4)
    c_x0, c_x1 = 18.0, 178.0
    ax.add_patch(plt.Rectangle((c_x0, 4.0), c_x1 - c_x0, 102.0, fc="#FAFAFD", ec=C_MAC_EDGE,
                               lw=1.4, zorder=1))
    ax.text(c_x0 + 1.5, 103.2, "omac_40g  (ip/omac_40g/rtl/omac_40g.sv)", ha="left",
            va="center", fontsize=9.6, weight="bold", color=TXT)
    clk_tag(ax, c_x1 - 1.5, 103.2, "clk = GT TXUSRCLK2 156.25 MHz (master channel)", ha="right")

    # ---- transmit path (clk) ----
    ty0, th = 82.0, 15.0
    yc = ty0 + th / 2
    tx = [
        (22.0, 16.0, "arbiter", "PAUSE first, then\nuser beats; no\ndead cycle\nbetween frames"),
        (41.0, 12.0, "pad", "to 60 B:\nzero beat or\nshort last\nbeat"),
        (56.0, 16.0, "FCS", "3-stage pipeline:\nrunning CRC over\nfull beats +\nthe last beat"),
        (75.0, 24.0, "column packer", "/S/ in any of the 4\n8-byte columns (two\nframes per beat), DIC\n"
                                      "0..7, 8-column buffer"),
        (102.0, 14.0, "RS TX", "LF / RF / idle\ncolumns"),
        (119.0, 30.0, "PCS TX", "enc66 x4, one scrambler over\nthe aggregate stream,\nlane l = column l,\n"
                                "AM every 16384 blocks + BIP3"),
    ]
    for (x, w, t, b) in tx:
        titled_box(ax, x, ty0, w, th, C_MAC_FILL, C_MAC_EDGE, t, b, title_fs=7.8, body_fs=6.5,
                   title_dy=1.9, z=3)
    for (x, w, _, _), (x2, _, _, _) in zip(tx[:-1], tx[1:]):
        harrow(ax, x + w, x2, yc, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=0.9)
    harrow(ax, 14.0, 22.0, yc, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.0)
    ptext(ax, 18.0, yc + 3.6, "s_axis_tx\n256 b", fs=6.4)
    harrow(ax, 149.0, 182.0, yc, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.1)
    ptext(ax, 165.5, yc + 3.6, "gt_tx_hdr / gt_tx_data\n[4 lanes]", fs=6.4)
    # ce: one cycle in 16384 held for the markers
    route(ax, [(134.0, ty0), (134.0, 79.0), (87.0, 79.0), (87.0, ty0)], C_THIN, lw=1.2, ms=7)
    ptext(ax, 110.5, 77.4, "ce: the TX path holds 1 cycle in 16384 for the markers",
          fs=6.3, color=C_MUTED)

    # ---- PAUSE, status, watchdog (clk) ----
    titled_box(ax, 22.0, 60.0, 30.0, 13.0, C_MAC_FILL, C_MAC_EDGE, "omac_pause  (common/)",
               "XOFF / refresh / XON requests;\nreceived pause timer at 40G\n→ stat_rx_pause_req (level)",
               title_fs=7.6, body_fs=6.4, title_dy=1.8, z=3)
    vblock(ax, 30.0, 73.0, ty0, C_USER_FILL, C_USER_EDGE, bw=0.8, hw=1.5, hl=1.0, double=False)
    route(ax, [(22.0, 63.0), (14.0, 63.0)], C_THIN, lw=1.2, ms=7)
    ptext(ax, 18.0, 65.3, "stat_rx_\npause_req", fs=5.8, color=C_MUTED)
    titled_box(ax, 56.0, 60.0, 34.0, 13.0, C_CTRL_FILL, C_CTRL_EDGE, "status and events",
               "stat_* incl. per-lane lock / map / skew:\nsynchronisers; ev_* (BIP per lane,\n"
               "skew fail, overflow): gray counters", title_fs=7.6, body_fs=6.4, title_dy=1.8,
               z=3)
    route(ax, [(56.0, 66.5), (54.0, 66.5), (54.0, 57.0), (14.0, 57.0)], C_CTRL_LINE, lw=1.2,
          ms=7)
    ptext(ax, 18.0, 54.8, "stat_*,\nev_*", fs=5.8, color=C_CTRL_LINE)
    titled_box(ax, 94.0, 60.0, 20.0, 13.0, C_MAC_FILL, C_MAC_EDGE, "watchdog",
               "no alignment for\na while: restart\nthe RX datapath", title_fs=7.6, body_fs=6.4,
               title_dy=1.8, z=3)

    # ---- per-lane receive front ends (gt_rx_clk[p]) ----
    dashed_group(ax, 126.0, 34.0, 49.0, 40.0, "gt_rx_clk[p]  (each lane its own clock)",
                 ec=C_REFCLK_LINE, fs=7.0)
    lane_y = [62.5, 54.5, 46.5, 38.5]
    for p, ly in enumerate(lane_y):
        box(ax, 133.0, ly - 3.0, 40.0, 6.0, C_MAC_FILL, C_MAC_EDGE,
            "lane %d: block lock + slip → AM lock +\nlane number → BIP3 check" % p, fs=6.2, z=3)
        box(ax, 117.0, ly - 3.0, 13.0, 6.0, C_CTRL_FILL, C_CTRL_EDGE,
            "lane FIFO %d\n68 b x 64" % p, fs=6.1, z=3)
        harrow(ax, 133.0, 130.0, ly, "", C_USER_FILL, C_USER_EDGE, bh=0.5, hh=1.0, hl=0.6)
        harrow(ax, 182.0, 173.0, ly, "", C_USER_FILL, C_USER_EDGE, bh=0.6, hh=1.1, hl=0.8)
    ptext(ax, 178.0, 69.0, "gt_rx_*\n[p]", fs=6.2)

    # ---- rclk: deskew ... MAC RX; clk: banks -> m_axis_rx ----
    dashed_group(ax, 40.0, 7.0, 92.0, 25.0, "rclk = gt_rx_clk[RX_CLK_LANE]  (one lane's clock)",
                 ec=C_REFCLK_LINE, fs=7.0)
    ry0, rh = 9.0, 18.0
    ryc = ry0 + rh / 2
    rx = [
        (22.0, 22.0, "banks 0 / 1", "32-byte chunks into\ntwo async FIFOs\n(264 b), read\nalternately in clk;\n"
                                    "full: frame cut or\ndropped (ev_rx_overflow)", C_CTRL_FILL, C_CTRL_EDGE),
        (48.0, 25.0, "MAC RX", "start + SFD scan, CRC\nresidue, re-alignment,\nFCS strip, MIN / MAX,\n"
                               "0x8808 filter, PAUSE\ndecode", C_MAC_FILL, C_MAC_EDGE),
        (76.0, 13.0, "RS fault", "link fault\nstate on\nlanes 0-3 of\neach column", C_MAC_FILL, C_MAC_EDGE),
        (92.0, 17.0, "decode", "BER monitor\n(N = 4),\ndescrambler,\ndecode x4 +\nRX state machine", C_MAC_FILL, C_MAC_EDGE),
        (112.0, 18.0, "deskew", "hold at the\nmarkers (up to\n32 blocks),\nreorder by lane\nnumber, AM removal", C_MAC_FILL, C_MAC_EDGE),
    ]
    for (x, w, t, b, fc, ec) in rx:
        titled_box(ax, x, ry0, w, rh, fc, ec, t, b, title_fs=7.8, body_fs=6.3, title_dy=1.9, z=3)
    for (x, w, *_), (x2, w2, *_) in zip(rx[:-1], rx[1:]):
        harrow(ax, x2, x + w, ryc, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=0.9)
    vblock(ax, 123.5, 35.5, ry0 + rh, C_USER_FILL, C_USER_EDGE, bw=0.9, hw=1.7, hl=1.1,
           double=False)
    ptext(ax, 125.8, 31.6, "4 lane FIFOs (flushed\nbefore each deskew)", ha="left", fs=6.2)
    harrow(ax, 22.0, 14.0, ryc, "", C_USER_FILL, C_USER_EDGE, bh=1.0, hh=1.9, hl=1.0)
    ptext(ax, 18.0, ryc + 4.4, "m_axis_rx\n256 b", fs=6.2)
    route(ax, [(56.0, ry0 + rh), (56.0, 45.0), (37.0, 45.0), (37.0, 60.0)], C_THIN, lw=1.2,
          ms=7)
    ptext(ax, 57.0, 47.0, "received pause_time (CDC)", ha="left", fs=6.3, color=C_MUTED)

    ax.text(100.0, 115.0, "omac_40g  —  40GBASE-R4 MAC + PCS (IEEE 802.3 clauses 81, 82)",
            ha="center", va="center", fontsize=13.0, weight="bold", color=TXT)
    ax.text(100.0, 110.6, "lavender: omac logic   grey: clock-domain crossings   cream: the "
            "transceivers   pale green: frames / 66-bit blocks   blue: control and status   "
            "dashed orange frames: recovered RX clock domains", ha="center", va="center",
            fontsize=7.0, color=C_MUTED)
    save(fig, "omac-40g-block.png")


# -----------------------------------------------------------------------------
# 3. UltraScale+ GTH wrappers.
#
# gt/omac_gt_usp_gth/omac_gt_usp_gth.sv, omac_gt_usp_gth_x4.sv, gen_gt.tcl.
# -----------------------------------------------------------------------------
def draw_gth():
    fig, ax = new_fig(19.0, 9.0, 180, 86)
    titled_box(ax, 2.0, 16.0, 26.0, 52.0, C_MAC_FILL, C_MAC_EDGE, "omac_10g",
               "(omac_40g with the\nfour-lane wrapper)\n\nGT side of the\ninterface contract:\n"
               "66-bit blocks,\nready / reset\nhandshake, slip,\nloopback", title_fs=9.0,
               body_fs=7.0, title_dy=2.4)
    w_x0, w_x1, w_y0, w_y1 = 50.0, 140.0, 10.0, 72.0
    ax.add_patch(plt.Rectangle((w_x0, w_y0), w_x1 - w_x0, w_y1 - w_y0, fc="#FAFAFD",
                               ec=C_MAC_EDGE, lw=1.4, zorder=1))
    ax.text(w_x0 + 1.5, w_y1 - 2.5, "omac_gt_usp_gth  (gt/omac_gt_usp_gth/omac_gt_usp_gth.sv)",
            ha="left", va="center", fontsize=8.8, weight="bold", color=TXT)
    titled_box(ax, 54.0, 52.0, 20.0, 9.0, C_GT_FILL, C_GT_EDGE, "IBUFDS_GTE4",
               "reference clock", title_fs=7.6, body_fs=6.6, title_dy=1.8, z=3)
    titled_box(ax, 54.0, 36.0, 20.0, 11.0, C_MAC_FILL, C_MAC_EDGE, "bit order",
               "bits reversed per\nblock (the gearbox\nsends MSb first)", title_fs=7.6,
               body_fs=6.4, title_dy=1.8, z=3)
    titled_box(ax, 54.0, 14.0, 20.0, 17.0, C_MAC_FILL, C_MAC_EDGE, "reset / ready",
               "reset_all, RX\ndatapath reset on\ngt_rx_reset_req,\nready to the IP,\nloopback select",
               title_fs=7.6, body_fs=6.4, title_dy=1.8, z=3)
    titled_box(ax, 80.0, 14.0, 56.0, 47.0, C_GT_FILL, C_GT_EDGE,
               "gtwizard_ultrascale  (omac_gth_10g)",
               "generated at build time by gen_gt.tcl\n(omac_gen_gth <ip_dir> <channel>; free IP, no key)\n\n"
               "GTHE4_CHANNEL, 10GBASE-R preset:\n64B/66B asynchronous gearbox,\n"
               "10.3125 Gb/s, user width 64 bits,\nQPLL0, TX / RX user clock 156.25 MHz\n\n"
               "reset controller on freerun_clk\n\nchannel LOC from the channel\ngiven to the generator",
               title_fs=8.2, body_fs=6.8, title_dy=2.2, z=3)
    harrow(ax, 74.0, 80.0, 56.5, "", C_GT_FILL, C_GT_EDGE, bh=0.6, hh=1.1, hl=0.8)
    harrow(ax, 74.0, 80.0, 41.5, "", C_USER_FILL, C_USER_EDGE, double=True, bh=0.6, hh=1.1,
           hl=0.8)
    harrow(ax, 74.0, 80.0, 22.5, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True, bh=0.6,
           hh=1.1, hl=0.8)
    # top inputs
    route(ax, [(64.0, 80.0), (64.0, 61.0)], C_REFCLK_LINE, lw=1.4, ms=8)
    ptext(ax, 64.0, 82.0, "refclk_p / refclk_n  156.25 MHz", fs=6.8, color=C_REFCLK_LINE,
          weight="bold")
    route(ax, [(100.0, 80.0), (100.0, 61.0)], C_REFCLK_LINE, lw=1.4, ms=8)
    ptext(ax, 100.0, 82.0, "freerun_clk", fs=6.8, color=C_REFCLK_LINE, weight="bold")
    route(ax, [(124.0, 80.0), (124.0, 61.0)], C_CTRL_LINE, lw=1.3, ms=8)
    ptext(ax, 124.0, 82.0, "reset_all (any clock)", fs=6.8, color=C_CTRL_LINE, weight="bold")
    # serial side
    titled_box(ax, 150.0, 26.0, 28.0, 24.0, C_FMC_FILL, C_FMC_EDGE, "serial lane",
               "gth_txp / gth_txn\ngth_rxp / gth_rxn\n\n(the channel's pins;\nno LOC constraint\nneeded)",
               title_fs=8.0, body_fs=6.7, title_dy=2.0)
    harrow(ax, 136.0, 150.0, 38.0, "", C_LINKARR_FILL, C_LINKARR_EDGE, double=True, bh=1.0,
           hh=1.9, hl=1.1)
    # IP <-> wrapper
    rows = [
        (63.0, "tx_usrclk2 → clk (+ user logic)", C_REFCLK_LINE, "clk"),
        (57.0, "rx_usrclk2 → gt_rx_clk", C_REFCLK_LINE, "clk"),
        (47.0, "gt_tx_hdr / gt_tx_data, gt_tx_ready", C_USER_EDGE, "tx"),
        (38.0, "gt_rx_hdr / data / valid, gt_rx_ready", C_USER_EDGE, "rx"),
        (26.0, "gt_rx_slip, gt_rx_reset_req, gt_loopback", C_CTRL_LINE, "ctl"),
    ]
    for (y, lab, col, kind) in rows:
        if kind in ("clk", "rx"):
            if kind == "rx":
                harrow(ax, w_x0, 28.0, y, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0)
            else:
                route(ax, [(w_x0, y), (28.0, y)], col, lw=1.4, ms=8)
        elif kind == "tx":
            harrow(ax, 28.0, w_x0, y, "", C_USER_FILL, C_USER_EDGE, bh=0.8, hh=1.5, hl=1.0)
        else:
            route(ax, [(28.0, y), (w_x0, y)], col, lw=1.3, ms=8)
        ptext(ax, 39.0, y + 2.4, lab, fs=6.0, color=col if kind in ("clk", "ctl") else TXT)
    notes(ax, 2.0, 0.0, 176.0, 8.0,
          "omac_gt_usp_gth_x4 (omac_40g): four channels of one quad (omac_gen_gth_x4 with the board's "
          "four channel sites in lane order, lane 0 = master)",
          "the same per lane, plus a lane-to-channel map (CH_OF_LANE), one shared TX user clock (the "
          "master's) and one RX user clock per lane (two BUFG_GT per channel from its own RXOUTCLK: "
          "the four-channel wizard has no RX buffer with the async gearbox)")
    ax.text(90.0, 85.6 + 2.6, "UltraScale+ GTH wrapper  —  omac IP ↔ transceiver",
            ha="center", va="center", fontsize=12.5, weight="bold", color=TXT)
    save(fig, "omac-gth-block.png")


def main():
    draw_10g()
    draw_40g()
    draw_gth()


if __name__ == "__main__":
    main()
