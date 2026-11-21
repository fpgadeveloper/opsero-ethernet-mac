# USXGMII in omac_10g

**Maturity (v0.2.0-dev): simulated** against an independent behavioural PHY model and
IP against IP at all six speeds, implemented out of context; **not yet run against a real
USXGMII PHY**. Some details of the protocol are taken from the publicly circulated USXGMII
*multiport* specification and must still be checked against the *single-port* specification
(see [Open protocol items](#open-protocol-items)); they are parameters, so a correction does not
need new RTL.

## What it is

USXGMII ("Universal SXGMII", single port) connects a MAC to a multi-rate Ethernet PHY (for
example a 10GBASE-T / NBASE-T copper PHY) over **one 10.3125 Gb/s lane at every link speed**:

* The lane is an ordinary 10GBASE-R lane: the clause 49 64B/66B PCS and scrambler, unchanged.
* **Rate adaptation by replication.** Below 10G every 32-bit XGMII word is sent N times
  (10G: 1, 5G: 2, 2.5G: 4, 1G: 10, 100M: 100, 10M: 1000), so the line rate stays 10.3125 Gb/s and
  the MAC's data rate is that of the copper link. The receiver keeps one word in N.
* **Auto-negotiation** between MAC and PHY (not the copper auto-negotiation, which the PHY does
  on its own): the PHY announces link, speed and duplex of its copper link in a 16-bit
  configuration word, carried in XGMII sequence ordered sets, with an exchange modelled on
  IEEE 802.3 clause 37 (the 1000BASE-X auto-negotiation that SGMII also uses).

With `USXGMII_EN` = 1, `omac_10g` does all three on the lane it already drives, so the same
transceiver wrapper and the same 156.25 MHz `clk` serve every speed. The MAC's AXI-Stream
interface, its timestamp hooks and its register-free control style stay as they are; the
stream simply runs at the link rate (`s_axis_tx_tready` is high in one cycle of N).

Sources: IEEE 802.3 clauses 46 (XGMII, sequence ordered sets, link fault signalling), 49
(64B/66B PCS) and 37 (the arbitration that USXGMII borrows); the public Cisco specification
"USXGMII - Multiport Specification" EDCS-1517762 (marked *Cisco Public*; its sections 1.1.1,
1.1.2, 2.5 and 2.6 describe the auto-negotiation word, its ordered set and the replication, and
section 2.6.3 says that its 2.5G-over-5G replication "is similar to single port USXGMII"); the
Linux kernel's USXGMII support (`MDIO_USXGMII_*` in `include/uapi/linux/mdio.h`,
`phylink_decode_usxgmii_word()`, the NXP Lynx PCS driver `drivers/net/pcs/pcs-lynx.c`). The
single-port specification itself (Cisco EDCS-1467841) was not available while this was
written.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `USXGMII_EN` | 0 | 1 adds rate adaptation and auto-negotiation (needs `SPEED` = 10). 0: the plain 10GBASE-R MAC + PCS; the `ctl_usx_*` inputs are ignored, the `stat_usx_*` / `ev_usx_*` outputs are 0, no logic is added |
| `USX_LINK_TIMER` | 250000 | auto-negotiation link timer in `clk` cycles: 1.6 ms at 156.25 MHz. `ctl_usx_link_timer` overrides it at run time |
| `USX_SOP_FILL` | 8'hAA | lane 0 of the copies of a replicated /S/ word (EDCS-1517762 2.6.1 / 2.6.3). The receiver accepts any data byte there |
| `USX_AN_OPCODE` | 8'h03 | lane 3 of the auto-negotiation ordered set (EDCS-1517762 1.1.2) |
| `USX_AN_LSWAP` | 0 | 0: word bits 15:8 in lane 1, 7:0 in lane 2 (EDCS-1517762 1.1.2); 1: the other way round |
| `USX_AN_TXFMT` | 0 | 0: the ordered set in both halves of every block (block type 0x55); 1: in the low half, idles in the high half (block type 0x4B). Both (and type 0x2D) are always received |
| `USX_IDLE_RESTART` | 1 | 1: three idle words received in AN_RESTART, ABILITY_DETECT or ACKNOWLEDGE_DETECT restart the exchange (the USXGMII replacement of clause 37's RUDI(INVALID) rule); 0: ignore idles there |

## Ports

All in `clk`. Present with `USXGMII_EN` = 0 too (inputs ignored, outputs 0).

| Port | Dir | Meaning |
|---|---|---|
| `ctl_usx_an_enable` | in | 1: auto-negotiation; 0: no exchange, the link runs at `ctl_usx_speed` ("forced", for PHYs without auto-negotiation and for tests) |
| `ctl_usx_an_restart` | in | rising edge: restart the exchange |
| `ctl_usx_an_adv[15:0]` | in | our configuration word (bit 14, acknowledge, is set by the arbitration). Typical: 0x9601 (link, full duplex, 10G, bit 0) |
| `ctl_usx_speed[2:0]` | in | the forced speed code (as word bits 11:9), used with `ctl_usx_an_enable` = 0 |
| `ctl_usx_link_timer[19:0]` | in | link timer in `clk` cycles; 0 = `USX_LINK_TIMER` |
| `ctl_usx_rx_strict` | in | 1: a frame in which a replica differs from its sample is delivered as bad (`tuser` = 1); 0: only counted |
| `stat_usx_an_complete` | out | the exchange is complete (LINK_OK) |
| `stat_usx_an_state[2:0]` | out | 0 AN_ENABLE, 1 AN_RESTART, 2 ABILITY_DETECT, 3 ACKNOWLEDGE_DETECT, 4 COMPLETE_ACKNOWLEDGE, 5 IDLE_DETECT, 6 LINK_OK, 7 AN disabled |
| `stat_usx_lp_word[15:0]` | out | the PHY's word as acknowledged in the last exchange |
| `stat_usx_speed[2:0]` | out | the speed code in use (from the PHY's word, or `ctl_usx_speed` with AN off) |
| `stat_usx_link_ok` | out | AN complete, the PHY's link bit set and a defined speed code (or AN off) |
| `ev_usx_an_start` | out | pulse: an exchange starts again after it had progressed (link change, lock loss, restart) |
| `ev_usx_an_done` | out | pulse: an exchange completed |
| `ev_usx_rep_error` | out | pulse: a replica inside a frame differed from its sample (one pulse per cycle with a mismatch) |

`stat_link_up` also requires `stat_usx_link_ok` when `USXGMII_EN` = 1, so a design's existing
carrier logic follows the PHY's copper link.

When the IP sits in a block design through `omac_10g_bd`, drive every `ctl_usx_*` input (an
unconnected input reads 0, which with `USXGMII_EN` = 1 means "AN off, 10M"); the optional
register block below does it.

### The configuration word

EDCS-1517762 table 2; the same bits as Linux `MDIO_USXGMII_*`:

| Bits | PHY to MAC | MAC to PHY (our `ctl_usx_an_adv`) |
|---|---|---|
| 15 | link of the copper port | the specification: "same as PHY to MAC" |
| 14 | acknowledge (set by the arbitration) | acknowledge (set by the arbitration) |
| 13 | reserved, 0 | reserved, 0 |
| 12 | 1 = full duplex | as PHY to MAC |
| 11:9 | speed: 000 10M, 001 100M, 010 1G, 011 10G, 100 2.5G, 101 5G, 110 / 111 reserved | as PHY to MAC |
| 8 | EEE capability | ours: 0 (no EEE) |
| 7 | EEE clock-stop capability | ours: 0 |
| 6:1 | reserved, 0 | reserved, 0 |
| 0 | 1 | 1 |

The IP takes speed, duplex and link from the PHY's word; its own word only needs to be
accepted by the PHY. Linux's NXP Lynx PCS driver programs its MAC-side word as link, full
duplex, 10G, bit 0 and acknowledge (0xD601); `ctl_usx_an_adv` = 0x9601 gives the same word on
the wire.

## Optional register block: omac_10g_usx_axil

`ip/omac_10g/rtl/omac_10g_usx_axil.sv` (in `omac_10g.f`, not instantiated by the IP): an
AXI4-Lite slave in `clk` that drives the `ctl_usx_*` inputs and reads the status, for designs
that do not fold the ports into a register block of their own.

| Offset | Register | Bits |
|---|---|---|
| 0x00 | ID | 0x55535847 ("USXG") |
| 0x04 | VERSION | `VERSION` parameter |
| 0x08 | CTRL | [0] AN_ENABLE (reset 1), [1] AN_RESTART (write 1, reads 0), [2] RX_STRICT, [6:4] FORCE_SPEED (reset 3 = 10G) |
| 0x0C | ADV | [15:0] our word (reset `ADV_INIT` = 0x9601) |
| 0x10 | LINK_TIMER | [19:0] in `clk` cycles, 0 = the IP's parameter |
| 0x14 | STATUS | [0] LINK_UP, [1] BLOCK_LOCK, [2] USX_LINK_OK, [3] AN_COMPLETE, [6:4] AN_STATE, [10:8] SPEED, [11] LP_LINK, [12] LP_FULL_DUPLEX |
| 0x18 | LP_WORD | [15:0] the PHY's acknowledged word |
| 0x1C | EVENTS | sticky, write 1 to clear: [0] REP_ERROR, [1] AN_RESTART, [2] AN_DONE, [3] LINK_DOWN, [4] LINK_UP |
| 0x20 | IRQ_EN | [4:0]; `irq` = \|(EVENTS & IRQ_EN) |
| 0x24 | REP_ERRORS | replica mismatches, saturating; any write clears |
| 0x28 | AN_DONES | completed exchanges, saturating; any write clears |

### Linux phylink PCS driver mapping

A `phylink_pcs` for `PHY_INTERFACE_MODE_USXGMII` (the MAC itself stays the design's netdev):

| phylink op | Registers |
|---|---|
| `pcs_get_state()` | `state->link` = STATUS.LINK_UP (block lock, no fault, AN complete with the PHY's link bit); `state->an_complete` = STATUS.AN_COMPLETE; then `phylink_decode_usxgmii_word(state, LP_WORD)` fills speed and duplex. With in-band AN off: speed from CTRL.FORCE_SPEED |
| `pcs_config()` | in-band (`PHYLINK_PCS_NEG_INBAND_ENABLED`): ADV = 0x9601, CTRL.AN_ENABLE = 1; otherwise CTRL.AN_ENABLE = 0. Optionally LINK_TIMER |
| `pcs_an_restart()` | CTRL = CTRL with AN_RESTART = 1 |
| `pcs_link_up()` | in-band off only: CTRL.FORCE_SPEED = the code of `speed` (10/100/1000/2500/5000/10000 -> 0/1/2/4/5/3) |
| interrupt | IRQ_EN = LINK_DOWN \| LINK_UP \| AN_DONE; the handler clears EVENTS and calls `phylink_pcs_change()` |
| statistics | REP_ERRORS (and the MAC's own counters) |

The PHY driver (for example `marvell10g` for some multi-rate PHYs) selects the PHY's USXGMII
host mode and in-band auto-negotiation; the PCS above then follows the PHY's copper speed.

## Transmit

* **Clock enable.** A counter in `clk` gives `omac_10g_mac_tx` (and the PAUSE timers) one enabled
  cycle in N. The MAC logic is the plain 10G MAC, only its register updates are enabled: it
  produces one 64-bit column per N cycles, accepts one AXI-Stream beat per N cycles
  (`s_axis_tx_tready` high one cycle in N) and keeps its 10G behaviour in every other respect
  (padding, FCS, deficit idle count, PAUSE frames, aborts). This was chosen over `tready`
  throttling in front of an unchanged MAC because the MAC emits a column in every cycle it runs:
  without an enable it would have to be followed by a frame buffer and an idle remover, and its
  inter-packet gap logic would no longer see the real gaps.
* **Replication** (`omac_10g_usx_tx`, one register). The low word of the held column fills the
  first N/2 output columns (in both halves), the high word the last N/2. The first copy of a
  word is the word itself; the copies follow EDCS-1517762 2.6.1 / 2.6.3:
  * the word with /S/ in its lane 0: copies with `USX_SOP_FILL` (0xAA, a data byte) in lane 0
    and the preamble in lanes 1-3 ("SOP word transmitted only once");
  * the word with /T/: copies are idle words ("EOP transmitted once and the remaining ... are
    idles");
  * every other word (data, idles, sequence ordered sets, error): identical copies ("all other
    sequence ordered sets and control sets are replicated").
  As N is even (or 1), every frame starts with /S/ in lane 0 of a block (block type 0x78) at
  N >= 2, and the 64B/66B encoder never sees two /S/ or two /T/ in a column.
* **Gaps.** The MAC's inter-packet gap (9-15 bytes, average 12, deficit idle count) is kept in
  bytes of the link speed: the regression measures a minimum of 9 bytes at every speed and a mean of
  11.75-12.0 bytes over the back-to-back frames (48 at 10G, 24 at 5G, 18 at 2.5G, 8 at 1G, 4 at 10M).
* **Auto-negotiation columns.** While the exchange runs, the RS sends configuration ordered sets
  (then idles in IDLE_DETECT) instead of the MAC's columns; Local Fault (`ctl_tx_fault`) and
  Remote Fault (our receiver has a local fault) still take priority. After LINK_OK the MAC's
  columns are passed from the next idle column on, so no frame starts in the middle.

## Receive

* **Sampling** (`omac_10g_usx_rx`, between the PCS and the MAC, in the recovered clock). Of the
  32-bit words of the decoded stream one in N goes to the MAC. Every word with /S/ in its lane 0
  is a sample and restarts the count (EDCS-1517762 2.6.2 / 2.6.4: "receive logic samples the
  1st 4-byte word containing SOP"). Inside a frame the PHY cannot insert or delete anything, so
  the phase found at /S/ holds to /T/; between frames the PHY's clock compensation may insert or
  delete idles, in units of 4 bytes, which moves the idle part only and may put the next /S/ in
  lane 4 of a block: both are handled, and an idle sample that falls in the low half of a block
  whose high half carries /S/ is dropped.
* **Columns to the MAC.** Samples are paired into 64-bit columns. A /S/ sample keeps the lane it
  had on the transceiver interface (an idle word fills the other half where needed), so the
  MAC's start-lane logic and the timestamp hooks see the original block position.
* **Replica check.** Inside a frame (from the /S/ sample to the copies of the /T/ word) each copy
  must equal its sample (the /S/ copies: data in lane 0, the preamble in lanes 1-3; the /T/
  copies: idle words). A mismatch pulses `ev_usx_rep_error`; with `ctl_usx_rx_strict` = 1 the
  next sample of the frame becomes an error word, so the MAC delivers the frame with `tuser` = 1.
  The default (0) only counts: a bit error in a copy that is not sampled does not damage the
  frame, while errors in a sample are caught by the FCS as at 10G. (As at 10G, a frame whose
  error comes within its first 4 bytes after the SFD is dropped rather than delivered bad: with
  strict checking that is a mismatch in a copy of the first data word.)
* **Link fault, BER, block lock** work on the undecimated stream exactly as at 10GBASE-R.
* **EEE / LPI.** Low-power-idle words (control code 0x06) are passed through and ignored between
  frames (tested: LPI words in the gaps at 5G); the IP never sends LPI, does not act on it and
  advertises no EEE capability.

## Auto-negotiation

`omac_10g_usx_an`. The receive side (recovered clock) extracts every configuration ordered set
(lane 0 /Q/ 0x9C, lane 3 `USX_AN_OPCODE`, in either half of a block, block types 0x55, 0x4B or
0x2D) and evaluates the clause 37 match functions on the word sequence: *ability_match* (three
consecutive words equal apart from bit 14), *acknowledge_match* (three equal words with bit 14
set), *idle_match* (three consecutive idle words). Single idle words between configuration
words do not break a run (so both transmit formats work); three idle words or any other word do.
A toggle-handshake crossing (`omac_cdc_word`) carries a consistent snapshot of the match
functions and the word into `clk`, about every 6-8 cycles: a word the partner sends for less
than that can go unseen by the arbitration (clause 37 partners hold each word much longer:
until their own match, then for a link timer).

The arbitration (`clk`) is figure 37-6 without next pages, with the USXGMII changes of
EDCS-1517762 1.1.1 / 2.5:

| State | Sends | Leaves for |
|---|---|---|
| AN_ENABLE | word 0 | AN_RESTART at once |
| AN_RESTART | word 0, link timer | ABILITY_DETECT when the timer expires |
| ABILITY_DETECT | `ctl_usx_an_adv` without bit 14 | ACKNOWLEDGE_DETECT on ability_match with a non-zero word |
| ACKNOWLEDGE_DETECT | `ctl_usx_an_adv` with bit 14 | COMPLETE_ACKNOWLEDGE on acknowledge_match with the same word (consistency); AN_ENABLE if inconsistent or on a zero word |
| COMPLETE_ACKNOWLEDGE | the same, link timer | IDLE_DETECT when the timer expires; AN_ENABLE on a zero word |
| IDLE_DETECT | idles, link timer | LINK_OK when the timer expired and idle_match; AN_ENABLE on a zero word |
| LINK_OK | data | AN_ENABLE on ability_match (the PHY sends words again: its copper link changed) |

Global: loss of block lock (instead of clause 37's `an_sync_status` = FAIL), a rising edge of
`ctl_usx_an_restart` and enabling auto-negotiation go to AN_ENABLE; with `USX_IDLE_RESTART` = 1,
idle_match in AN_RESTART, ABILITY_DETECT or ACKNOWLEDGE_DETECT does too (the USXGMII
replacement of RUDI(INVALID)). At LINK_OK the PHY's word (`stat_usx_lp_word`) sets the
replication of both directions; `stat_usx_link_ok` needs its link bit and a defined speed code.
Half duplex is reported in the word but not supported (the MAC is full duplex only).

A speed change is a new exchange: the PHY sends its new word, the IP leaves LINK_OK, both sides
negotiate again and the new replication applies from LINK_OK. Frames in flight at that moment
are lost (as on any link change). The regression changes the speed on the fly through every
speed, with the PHY model restarting both ways (the whole exchange, or a "re-signal" straight
from link-ok to ability detect with the new word). With the default 1.6 ms link timer an exchange
takes about 4.9 ms (three link timers plus the word exchanges; 760k cycles in simulation).

## Timestamps

The timestamp hooks (`TS_EN` = 1) keep their reference plane at every speed: **the 66-bit
block that carries the first copy of the frame's /S/ on the transceiver interface** (transmit:
the `clk` cycle the block is on `gt_tx_data`; receive: the `gt_rx_clk` cycle it is on
`gt_rx_data`). Replication adds nothing to the timestamp path inside the IP: the regression
checks, at every speed and frame by frame, that the transmit value is the cycle of the /S/
block seen by the PHY model and that the receive value is the cycle in which the PHY model sent
its /S/ block plus the channel latency (3 cycles), with /S/ in lane 0 or 4.

What changes with the speed is where the frame's bits are relative to that block, and the PHY:

| Speed | N | one 32-bit word on the lane | /S/ block to the end of the SFD (the IEEE 1588 / 802.3 clause 90 message timestamp point) | TX /S/ lane | RX lane-4 offset |
|---|---:|---:|---:|---|---:|
| 10G | 1 | 3.2 ns | 6.4 ns (64 bit times at 10G) | 0 or 4 (`tx_ts_lane4`) | 3.103 ns |
| 5G | 2 | 6.4 ns | 12.8 ns | 0 | 3.103 ns |
| 2.5G | 4 | 12.8 ns | 25.6 ns | 0 | 3.103 ns |
| 1G | 10 | 32 ns | 64 ns | 0 | 3.103 ns |
| 100M | 100 | 320 ns | 640 ns | 0 | 3.103 ns |
| 10M | 1000 | 3.2 us | 6.4 us | 0 | 3.103 ns |

* The SFD offset is 64 bit times of the link speed (N x 6.4 ns), constant per speed: software
  that wants the clause 90 timestamp point adds it per speed (at 10G it is the 6.4 ns it adds
  today).
* Lane 4: at N >= 2 the IP always starts a frame in lane 0. A received /S/ may still be in lane
  4 (the PHY deleted or inserted an odd number of idle words), `m_axis_rx_ts_lane4` says so and
  the 32-bit offset (3.103 ns, as at 10G) applies at every speed.
* **The PHY's own latency** between its host lane and the copper (MDI) is outside the IP and
  differs per speed (and per PHY, and possibly per link-up). It must be calibrated per speed:
  ptp4l `egressLatency` / `ingressLatency` per speed, or a per-speed table in the driver.
  With SyncE (both ends of the host lane from the same clock family) the PHY's synchronising
  FIFO should be static; without it, it can move by a few word times between link-ups.
* Resolution: one block (6.4 ns) on transmit, one `clk` period on receive (as at 10G),
  independent of the speed; at 1G that is about 6 bit times, at 10M far below one bit time.

## Latency (data, not timestamps)

Transmit: the MAC's own 7 or so columns, each now N cycles long, plus one register of
replication; a beat waits up to N cycles for its enabled cycle. Receive: the PCS as at 10G plus
one register of sampling; a column reaches the MAC when its second sample arrives (N words
after the first).

## Cost

[](resources.md#omac_10g): the `USXGMII_EN` = 1 jobs and their deltas against the same jobs with
`USXGMII_EN` = 0.

## Verification

* `usx_speeds`, `usx_corrupt`, `usx_forced`, `usx_antimer`, `usx_axil`
  (`ip/omac_10g/sim/test_omac_10g_usx.py`): one IP against `tb_usx_phy`, a behavioural model of
  a USXGMII PHY's host side written from the protocol description (its own 64B/66B encoder and
  decoder, scrambler, CRC, replication, de-replication and arbitration; no omac code). The
  PHY model checks every replication rule on the IP's stream; it injects idle insertion and
  deletion of single 4-byte words (start lane 0 / 4), LPI words, wrong FCS, corrupted copies,
  block-lock loss (a burst of invalid sync headers) and changes the speed on the fly through
  10G, 1G, 2.5G, 5G, 100M and 10M. Frames of 60-9000 bytes both ways, mostly back to back.
* `usx_loop10g` ... `usx_loop10m`: two IPs against each other at each speed through the
  bit-level channel model, with the transmitted wire decoded by an independent Python model
  (`omac_ref.parse_capture_usx`) that checks the replication rules and the gaps; aborts,
  underflows, oversize frames, PAUSE frames, line bit flips, timestamps.
* `usx_pause1g`, `usx_pause2p5g`: PAUSE quanta in bit times of the link speed.
* `10g_*_usx`: the 10GBASE-R tests with `USXGMII_EN` = 1 (auto-negotiated 10G).
* With `USXGMII_EN` = 0 every pre-existing omac_10g test gives byte-identical outputs (wire
  captures, received frames, timestamps) to the IP before USXGMII was added.

Results and the fault-injection (mutation) check: [](simulation.md#usxgmii).

## Limitations

* Single port only (no USXGMII-M multi-port: no port multiplexing, no alignment markers), no
  packet control header (PCH), no EEE / LPI generation, full duplex only.
* The protocol details listed below follow the public multiport specification and the
  description of clause 37; they are parameters where they are uncertain.
* Speeds change only through a new exchange (or `ctl_usx_speed` with AN off).
* Not yet tested against a real PHY.

## Open protocol items

To be checked against the single-port specification (Cisco EDCS-1467841) and a real PHY.
"Ours" is what the IP does today.

1. **Ordered-set layout of the word.** Ours (EDCS-1517762 1.1.2, table 3): lane 0 /Q/ (0x9C),
   lane 1 word[15:8], lane 2 word[7:0], lane 3 0x03. Byte order and opcode for single port?
   (`USX_AN_LSWAP`, `USX_AN_OPCODE`.)
2. **How densely the words are sent.** Ours: in both halves of every block (block type 0x55);
   alternative: low half + idles (0x4B). Does the PHY need idles in between (clock
   compensation), is there a required repetition rate? (`USX_AN_TXFMT`; both received.)
3. **Replication during auto-negotiation.** Ours: configuration words and the IDLE_DETECT idles
   are sent and received at the 10G word rate, never replicated.
4. **Match functions.** Ours: three consecutive words per ordered set (not per block); single idle
   words between words ignored; idle_match = three consecutive idle 32-bit words.
5. **The "idle received" restart** (EDCS-1517762 1.1.1: "rudi(invalid) changed to idle received
   during an_restart, ability_detect, acknowledge_detect"). Ours: idle_match (three idle words)
   restarts; a single idle does not. (`USX_IDLE_RESTART`.)
6. **Link timer.** Ours: 1.6 ms (EDCS-1517762 1.1.2 "like SGMII ... 1.6 ms"), programmable at run
   time (1.1.1: "configurable from 1 msec to 2 msec in steps of 0.1 msec").
7. **The MAC's word.** Table 2 says bits 15, 12 and 11:9 from MAC to PHY are "same as PHY to MAC";
   clause 37's consistency check needs the MAC's word to be the same in ability and
   acknowledge. Ours: a fixed programmable word (default 0x9601, as Linux pcs-lynx), not an
   echo. Does a PHY require the echo?
8. **Link-change signalling by the PHY** (1.1.2: "re-signal ... until message is received with
   Auto-negotiation acknowledge bit set to 1 or for the duration of the link timer"). Ours: any
   ability_match in LINK_OK restarts the full exchange; tested against both a PHY that restarts
   from scratch and one that re-signals from link-ok.
9. **Copies of the /S/ word.** Ours: lane 0 = 0xAA (data), lanes 1-3 = the preamble
   (EDCS-1517762 2.6.3 example "555555fb 555555aa"). Single port: 0xAA too? (`USX_SOP_FILL`;
   the receiver does not check that byte.)
10. **Copies of the /T/ word.** Ours: idle words (2.6.3: "EOP is transmitted once and the
    remaining ... are idles"). 2.6.1 words it as "EOP byte is replaced with idle", which for a
    word with data before /T/ would not be encodable in a 64B/66B block; the receiver expects
    idle words (only the replica counter would notice a difference, the frame is unaffected).
11. **Alignment.** Ours: replication groups start at the /S/ word, which is in lane 0 of a block
    at N >= 2; the receiver restarts its sampling phase at every /S/, in lane 0 or 4.
12. **Gap at replicated speeds.** Ours: the 10G deficit idle count, i.e. 9-15 bytes (average 12)
    of the link speed between frames. Does the PHY need at least 12 bytes at 1G and below?
13. **Preamble.** Ours: 7 bytes + SFD at every speed (EDCS-1517762 2: the PHY adds bytes to make
    7 + SFD towards the MAC).
14. **Restart conditions.** Ours: block-lock loss restarts; hi BER, link faults and errors do not
    (2.5.1: "USXGMII Auto-neg is NOT re-started due to error/link fault conditions").
15. **Faults during auto-negotiation.** Ours: Local / Remote Fault columns replace the
    configuration words (2.5.1: "if Tx MAC transmits errors or link faults, the auto-negotiation
    is interrupted"). In particular, while the PHY sends Local Fault on its host lane we answer
    with Remote Fault and no configuration words: a PHY that waits for our words before it stops
    sending Local Fault would never complete. What does a PHY send on its host lane before and
    during the exchange?
16. **EEE.** Bits 8 / 7 are not acted on; how LPI is replicated is not specified here (we never
    send it and ignore it on receive).
