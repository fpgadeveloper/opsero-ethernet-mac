# USXGMII in omac_10g

**Maturity (v0.2.0-dev): simulated** against an independent behavioural PHY model and
IP against IP at all six speeds, implemented out of context, and checked point by point against
the single-port USXGMII specification ([Specification check](#specification-check));
**not yet run against a real USXGMII PHY**.

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

The interface to the transceiver is unchanged, so every transceiver wrapper of this repository
carries USXGMII lanes as it is: the UltraScale+ GTH / GTY quad wrappers and the Versal GTY quad
wrapper, at the 10GBASE-R line rate. `USXGMII_EN` is a parameter of each `omac_10g` instance, so
the lanes of one quad may mix USXGMII and 10GBASE-R ports.

Sources: the Cisco specification "Universal SXGMII Interface for a Single MultiGigabit Copper
Network Port" (USXGMII single port, EDCS-1150953, revision 2.5, published by Cisco as a public
document; called *the specification* below, with its section numbers); IEEE 802.3 clauses 46
(XGMII, sequence ordered sets, link fault signalling), 49 (64B/66B PCS) and 37 (the arbitration
that USXGMII borrows); the Linux kernel's USXGMII support (`MDIO_USXGMII_*` in
`include/uapi/linux/mdio.h`, `phylink_decode_usxgmii_word()`, the NXP Lynx PCS driver
`drivers/net/pcs/pcs-lynx.c`). The specification is not reproduced here; it is available from
Cisco, with its own intellectual-property terms.

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `USXGMII_EN` | 0 | 1 adds rate adaptation and auto-negotiation (needs `SPEED` = 10). 0: the plain 10GBASE-R MAC + PCS; the `ctl_usx_*` inputs are ignored, the `stat_usx_*` / `ev_usx_*` outputs are 0, no logic is added |
| `USX_LINK_TIMER` | 250000 | auto-negotiation link timer in `clk` cycles: 1.6 ms at 156.25 MHz, the specification's default (1.1.2; it allows 1.0 to 2.0 ms in steps of 0.1 ms, 1.1.1). `ctl_usx_link_timer` overrides it at run time |
| `USX_SOP_FILL` | 8'hAA | lane 0 of the copies of a replicated /S/ word (specification 2.6.1). The receiver accepts any data byte there |
| `USX_AN_OPCODE` | 8'h03 | lane 3 of the auto-negotiation ordered set (specification 1.1.2) |
| `USX_AN_LSWAP` | 0 | 0: word bits 15:8 in lane 1, 7:0 in lane 2 (specification 1.1.2); 1: the other way round (not conforming; only for a PHY that needs it) |
| `USX_AN_TXFMT` | 0 | 0: the ordered set in both halves of every block (block type 0x55); 1: in the low half, idles in the high half (block type 0x4B). Both are layouts the specification shows (1.1.2); both (and type 0x2D) are always received. Keep 0: see [Specification check](#specification-check), item 2 |
| `USX_IDLE_RESTART` | 1 | 1: three idle words received in AN_RESTART, ABILITY_DETECT or ACKNOWLEDGE_DETECT restart the exchange (the USXGMII replacement of clause 37's RUDI(INVALID) rule, specification 1.1.1); 0: ignore idles there (not conforming) |

## Ports

All in `clk`. Present with `USXGMII_EN` = 0 too (inputs ignored, outputs 0).

| Port | Dir | Meaning |
|---|---|---|
| `ctl_usx_an_enable` | in | 1: auto-negotiation; 0: no exchange, the link runs at `ctl_usx_speed` ("forced": software reads the PHY's speed over MDIO and programs it, specification 2.6.8; the PHY's own in-band auto-negotiation must then be off too, or it keeps sending configuration words; also for tests) |
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

Specification 1.1.2; the same bits as Linux `MDIO_USXGMII_*`:

| Bits | PHY to MAC | MAC to PHY (our `ctl_usx_an_adv`) |
|---|---|---|
| 15 | link of the copper port | link, defined as in the other direction |
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

The PHY's own Linux driver selects the PHY's USXGMII
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
  word is the word itself; the copies follow specification 2.6.1:
  * the word with /S/ in its lane 0 is sent once; its copies carry `USX_SOP_FILL` (0xAA, a data
    byte) in lane 0 and the preamble in lanes 1-3;
  * the word with /T/ is sent once; its copies are idle words;
  * every other word (data, idles, sequence ordered sets, error): identical copies.
  The replication sits between the MAC (with its reconciliation sublayer) and the unchanged
  clause 49 encoder, on 4-byte XGMII words (specification 1 and 2).
  As N is even (or 1), every frame starts with /S/ in lane 0 of a block (block type 0x78) at
  N >= 2, and the 64B/66B encoder never sees two /S/ or two /T/ in a column.
* **Gaps.** The MAC's inter-packet gap (9-15 bytes, average 12, deficit idle count) is kept in
  bytes of the link speed: the regression measures a minimum of 9 bytes at every speed and a mean of
  11.75-12.0 bytes over the back-to-back frames (48 at 10G, 24 at 5G, 18 at 2.5G, 8 at 1G, 4 at 10M).
* **Auto-negotiation columns.** While the exchange runs, the RS sends configuration ordered sets
  (then idles in IDLE_DETECT) instead of the MAC's columns, which are discarded; Local Fault
  (`ctl_tx_fault`) and Remote Fault (our receiver has a local fault) still take priority, as the
  specification requires for link faults (2.5.1). After LINK_OK the MAC's columns are passed from
  the next idle column on, so no frame starts in the middle.

## Receive

* **Sampling** (`omac_10g_usx_rx`, between the PCS and the MAC, in the recovered clock). Of the
  32-bit words of the decoded stream one in N goes to the MAC. Every word with /S/ in its lane 0
  is a sample and restarts the count (specification 2.6.2 and step 8 of 2.6.7: the sampling
  point is set again at every /S/). Inside a frame the PHY cannot insert or delete anything, so
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
* **Link fault, BER, block lock** work on the undecimated stream exactly as at 10GBASE-R. (The
  specification passes link fault words through the sampler like everything else, 2.6.2; for a
  PHY that replicates its fault ordered sets, as it must, both give the same fault state, the
  undecimated detector only clears a fault after 128 line columns instead of 128 samples.)
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
specification 1.1.1 (repeated in 2.5):

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
replacement of RUDI(INVALID)). Hi BER, link faults and errors do not restart the exchange
(specification 2.5.1). At LINK_OK the PHY's word (`stat_usx_lp_word`) sets the replication of
both directions (specification 2.6.7, step 8); `stat_usx_link_ok` needs its link bit and a
defined speed code. Half duplex is reported in the word but not supported: the MAC-PHY interface
is full duplex only (specification 1), so the PHY must not advertise half-duplex modes on its
copper side.

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
  packet control header (PCH, optional in the specification, 1.1.3), no EEE / LPI generation,
  full duplex only, 10G-SXGMII only (no 5.15625 Gb/s lane option).
* No software-controlled negotiation mode (specification 2.6.8 describes it as an alternative to
  the hardware exchange): with auto-negotiation off the speed is forced (`ctl_usx_speed`) and no
  configuration words are sent.
* Speeds change only through a new exchange (or `ctl_usx_speed` with AN off).
* Not yet tested against a real PHY.

## Specification check

Every protocol choice of the IP, checked against the single-port specification. "Conforms":
the specification states the behaviour and the IP has it; "not specified": the specification
leaves it open, the IP's choice is given with the reason.

| # | Item | Specification | IP |
|---|---|---|---|
| 1 | Layout of the configuration ordered set | 1.1.2: conforms | lane 0 /Q/ (0x9C, sequence ordered set), lane 1 word[15:8], lane 2 word[7:0], lane 3 opcode 0x03 (`USX_AN_LSWAP` = 0, `USX_AN_OPCODE` = 0x03) |
| 2 | Block layout of the configuration columns | 1.1.2 shows the ordered set alone (with idles, block type 0x4B), after idles (0x2D) and in both halves (0x55); no repetition rate is specified | sends 0x55 (both halves), receives all three. 0x55 keeps every 32-bit word a configuration word, so a PHY that still samples one word in N (it has not yet left its replicated mode) sees the words at any phase; with 0x4B it could sample only the idle halves. Clock compensation by the PHY then deletes one of two consecutive sequence ordered sets (which IEEE 802.3 allows) rather than an idle |
| 3 | Replication during auto-negotiation | 2.6.7 steps 2 and 8: the exchange runs on the unreplicated lane, replication starts at completion | conforms. The configuration columns are identical words, so they are also a valid replicated stream for a partner still at a lower speed |
| 4 | Match functions | 1.1.1: as figure 37-6; 2.6.5: three consecutive identical words | ability_match / acknowledge_match on three consecutive ordered sets; single idle words between them do not break a run (needed for the 0x4B and 0x2D layouts) |
| 5 | Idles in AN_RESTART, ABILITY_DETECT, ACKNOWLEDGE_DETECT | 1.1.1: received idles take the place of clause 37's RUDI(INVALID) in these three states | conforms (`USX_IDLE_RESTART` = 1). What counts as "idles received" is not specified; the IP needs three consecutive idle words, so single idles of the 0x4B / 0x2D layouts do not restart |
| 6 | Link timer | 1.1.2: 1.6 ms; 1.1.1: configurable 1.0 to 2.0 ms in 0.1 ms steps; no tolerance stated | 1.6 ms (250000 cycles of 156.25 MHz), any value at run time |
| 7 | The MAC's word | 1.1.2: same bit layout in both directions, the MAC sets bit 0 and the acknowledge bit; whether the MAC's link / duplex / speed must echo the PHY's is not specified | a programmable word, default 0x9601 (link, full duplex, 10G, bit 0), acknowledge added by the arbitration |
| 8 | Link change signalled by the PHY | 1.1.1: the exchange restarts whenever the copper link changes; 1.1.2: the PHY sends its words until acknowledged or for one link timer | any ability_match in LINK_OK restarts the exchange (clause 37 LINK_OK); tested with a partner that restarts from scratch and one that re-signals directly |
| 9 | Copies of the /S/ word | 2.6.1: sent once, the copies carry 0xAA in lane 0, the preamble in lanes 1-3 | conforms (`USX_SOP_FILL`); the receiver accepts any data byte there |
| 10 | Copies of the /T/ word | 2.6.1: sent once, the copies are idle words | conforms |
| 11 | Receive sampling | 2.6.2, 2.6.7 step 8: one word in N from the /S/ word on, the phase set again at every /S/ | conforms, /S/ in lane 0 or 4 |
| 12 | Gap at replicated speeds | 2.8.1.1 / 2.8.2.1: the PHY accepts gaps down to 5 bytes from the MAC | 9-15 bytes, average 12, in bytes of the link speed (the 10G deficit idle count) |
| 13 | Preamble | 1, 2.2: 7 bytes + SFD in both directions (the PHY pads a short preamble); 2.7: the PCH replaces it only when that option is on | standard preamble; PCH not supported |
| 14 | Restart conditions | 1.1.1: loss of block lock; 2.5.1: not on errors or link faults; software restart | conforms (block lock lost, `ctl_usx_an_restart`, enabling AN) |
| 15 | Faults during the exchange | 2.5.1: link faults from the MAC side interrupt the configuration words and pass through; 2.8.1: a PHY whose copper side is still negotiating sends idles or Local Fault | conforms: Local / Remote Fault replace the configuration words. A PHY set to send Local Fault while its copper side negotiates gets Remote Fault back; when it starts sending its words (copper link up) the IP's Remote Fault ends 128 columns after the last Local Fault and the exchange proceeds |
| 16 | EEE | 1.1.2: capability bits 8 (EEE) and 7 (clock stop); LPI is a control set and is replicated like the others (2.6.1) | advertises neither; LPI received between frames is ignored, never sent |
| 17 | Speed codes, duplex | 1.1.2: 000 10M, 001 100M, 010 1G, 011 10G, 100 2.5G, 101 5G, 110 / 111 reserved; bit 12 full duplex; the interface itself is full duplex only (1) | conforms; reserved codes give no link; half duplex is not supported |
| 18 | Replication factors | table 1 and 2.6.1 for 10.3125 Gb/s: 100M x100, 1G x10, 2.5G x4, 5G x2, 10G x1; 10M by the corresponding factor (x1000) | conforms |
| 19 | Where the replication sits | 1, 2: on 4-byte XGMII words between the MAC and an unchanged clause 49 PCS | conforms |
| 20 | Auto-negotiation disabled | 1.1.1: without the PHY's USXGMII mode both sides run plain 10GBASE-R; 2.6.8: software may program the speed itself | `ctl_usx_an_enable` = 0: the speed is forced; with `USXGMII_EN` = 0 the IP is the plain 10GBASE-R MAC + PCS |
| 21 | PAUSE, flow control | 2.4: no USXGMII-level flow control or other rate adaptation; PAUSE frames are payload | PAUSE quanta in bit times of the link speed |
| 22 | Clocking | 2.6.6: auto-negotiation in the PCS / MAC clock; no frequency tolerance beyond clause 49 | AN arbitration in `clk`, matching in the recovered clock |
