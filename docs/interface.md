# Interface contract

**Status: frozen for v0.1.0.** This page defines the ports and the behaviour that
every `omac_*` IP of this repository presents to the design around it, so that a design (and the
engine behind the MAC) can swap one MAC for another by changing the instance, not the logic
around it. A wrapper around a hard MAC (for example the UltraScale+ 100G CMAC) can implement the
same boundary. Any change to a port name, width or
meaning after v0.1.0 is listed in the [change log](#change-log) at the end of this page, with
its date, and named in the commit message.

The contract has two parts:

| Part | Mandatory for every omac IP | Contents |
|---|---|---|
| [User side](#1-user-side-mandatory) | **yes** | one user clock, AXI-Stream TX and RX, the control bundle `ctl_*`, the status bundle `stat_*`, the event bundle `ev_*` |
| [GT side](#2-gt-side-per-ip) | no (per IP) | the transceiver interface: 66-bit blocks, user clocks, reset handshake, block slip, loopback. Defined here for the 64B/66B IPs (`omac_10g`, `omac_40g`); a hard-MAC wrapper has none |
| [Statistics](#3-optional-axi-lite-statistics) | no (optional block) | `common/omac_axil_stats`: AXI-Lite counters fed by the `ev_*` pulses |
| [Software contract](#6-software-contract) | yes, for the design around the IP | what the design's own registers must expose and how software uses it. **The repository ships no driver** (no register block inside the IPs, no Linux netdev, no bare-metal library) |

Byte order on every AXI-Stream: byte *i* of a frame is `tdata[8*i +: 8]` (byte 0 = the first byte
of the destination address, first on the wire); `tkeep[i]` qualifies it.

## 1. User side (mandatory)

### 1.1 Clock and reset

| Port | Dir | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | **the one user clock**. All user-side ports (AXI-Stream TX and RX, `ctl_*`, `stat_*`, `ev_*`) are synchronous to it. For the 64B/66B IPs it is the GT **TX** user clock (`TXUSRCLK2`): 156.25 MHz for 10GBASE-R (64-bit) and 40GBASE-R4 (256-bit), 390.625 MHz for 25GBASE-R (64-bit) |
| `rst` | in | 1 | synchronous to `clk`, active high, at least 4 cycles. Resets both directions; the RX side is reset in its own clock through an internal reset synchroniser. The IP also holds its TX side in reset while `gt_tx_ready` = 0 and its RX side while `gt_tx_ready` or `gt_rx_ready` = 0, so `rst` does not need to include them |

The receive side of a 64B/66B PCS runs on the **recovered** clock of the transceiver (the far
end's transmit clock, up to ±100 ppm away from `clk`). The IP crosses received frames into `clk`
through an internal asynchronous FIFO, so the user never sees the recovered clock. A hard MAC
whose RX and TX streams are already in one clock (CMAC: `rx_clk` = `gt_txusrclk2`) satisfies the
contract directly.

`clk` comes out of the transceiver, so it **stops** while the transceiver is in reset or has no
reference clock. Software must not depend on registers clocked by `clk` being reachable at those
times ([6.1](#61-clock-domains-keep-the-registers-reachable)).

### 1.2 Transmit AXI-Stream (`s_axis_tx_*`)

| Port | Dir | Width | Description |
|---|---|---|---|
| `s_axis_tx_tdata` | in | `DATA_WIDTH` | frame bytes from the destination address to the end of the payload, **without FCS** |
| `s_axis_tx_tkeep` | in | `DATA_WIDTH/8` | all ones on every beat except the last; on the last beat contiguous from bit 0, at least one bit set |
| `s_axis_tx_tvalid` | in | 1 | |
| `s_axis_tx_tready` | out | 1 | |
| `s_axis_tx_tlast` | in | 1 | last beat of a frame |
| `s_axis_tx_tuser` | in | 1 | **abort**: on any beat, the frame is ended on the wire with an error code (the receiver discards it); the remaining beats of the frame up to `tlast` are accepted and discarded. Tie 0 if unused |

Rules:

* **No gaps inside a frame.** Once the first beat of a frame has been accepted, `tvalid` must stay
  high on every cycle the IP asserts `tready` until `tlast` has been accepted (use a
  store-and-forward FIFO upstream). The IP drops `tready` inside a frame on its own (preamble,
  FCS, inter-packet gap, PAUSE insertion); that is normal back-pressure. If `tvalid` is low on a cycle where the IP needs the next beat, the frame is
  aborted on the wire (error code) and `ev_tx_underflow` pulses; the rest of the frame is
  accepted and discarded.
* The IP **pads** frames shorter than 60 bytes with zero bytes to 60 bytes and **appends the FCS**
  (so the minimum frame on the wire is 64 bytes). There is no maximum length check on transmit.
* The IP inserts the preamble, the start of frame delimiter and the inter-packet gap (12 bytes on
  average, deficit idle count). On the wire `omac_10g` starts frames on 4-byte boundaries
  (lane 0 or 4 of the XGMII column), `omac_40g` on 8-byte boundaries (lane 0 of any of the four
  XLGMII columns of a beat). On the AXI-Stream a frame always starts at byte 0 of a beat.
* Frames are only started while `ctl_tx_enable` = 1 and, with `ctl_pause_tx_honour` = 1, while
  no received PAUSE is in force (`stat_rx_pause_req` = 0). While held, `tready` is low between
  frames; a frame already started is always completed.
* While the link reports a fault (the IP sends Remote Fault or idles, see 1.6) frames keep being
  accepted at line rate and are discarded on the wire, as on a cable with no partner. Before the
  transceiver is ready (`gt_tx_ready` = 0) the TX side is held in reset and `tready` is low.

### 1.3 Receive AXI-Stream (`m_axis_rx_*`)

| Port | Dir | Width | Description |
|---|---|---|---|
| `m_axis_rx_tdata` | out | `DATA_WIDTH` | received frame bytes from the destination address, **FCS stripped** |
| `m_axis_rx_tkeep` | out | `DATA_WIDTH/8` | all ones except on the last beat (contiguous from bit 0, at least one bit set) |
| `m_axis_rx_tvalid` | out | 1 | |
| `m_axis_rx_tlast` | out | 1 | |
| `m_axis_rx_tuser` | out | 1 | **bad frame**, valid on the `tlast` beat: FCS error, length error (shorter than `MIN_FRAME` or longer than `MAX_FRAME`), or a PCS/RS error inside the frame (error code, invalid block, sequence error, frame start without a proper SFD is not delivered at all). The sink must discard the frame (or count it) |

Rules:

* **No `tready`.** The sink must accept every beat on the cycle it is presented, at line rate
  (the hard CMAC has the same rule).
* **`tvalid` may drop at any time, also inside a frame.** The IP delivers beats as they leave the
  internal clock-crossing FIFO: a frame normally comes out in consecutive cycles, but single-cycle
  gaps occur at the ppm rate of the clock difference, plus gaps from the realignment and the FCS
  strip at frame ends (omac_40g: also the marker cycle and the lane FIFOs). A sink that keeps per-beat state (for example a FIFO that writes every valid beat) needs
  nothing special; a sink that assumes back-to-back beats must not be used.
* The rate never exceeds one beat per `clk` cycle. There is no minimum spacing between frames:
  the first beat of a frame may directly follow the `tlast` beat of the previous one.
* Wide IPs and line rate: with one frame per beat and the beat rate equal to the line rate
  (omac_40g: 32 bytes x 156.25 MHz = 40.0 Gb/s), frames whose length without FCS is 1..7 bytes
  more than a multiple of the beat width can need more beats than cycles when they arrive back to
  back at the minimum gap. The IP buffers bursts of them in its clock-crossing FIFO; beyond that
  it cuts or drops whole frames (`tuser` = 1 / not delivered, IP-specific `ev_rx_overflow`) and
  never delivers a corrupted frame as good. See the IP page for the numbers.
* Frames of 4 bytes or less after the FCS (nothing left to deliver) are dropped and counted in
  `ev_rx_frame_bad`.
* Frames that start while `ctl_rx_enable` = 0 are dropped silently: `ev_rx_frame_good` and
  `ev_rx_frame_bad` do not count them; `ev_rx_fcs_error`, `ev_rx_runt` and `ev_rx_oversize` still
  do, and a valid PAUSE frame among them still loads the PAUSE timer.
* MAC Control frames (EtherType 0x8808, including PAUSE) are **consumed** by the IP and never
  delivered; they are not counted in `ev_rx_frame_good` / `ev_rx_frame_bad` (a valid PAUSE frame
  counts in `ev_rx_pause`, a control frame with a bad FCS in `ev_rx_fcs_error`). A valid PAUSE
  frame (good FCS, opcode 0x0001, destination 01-80-C2-00-00-01 or `ctl_mac_addr`) loads the
  PAUSE timer (1.5).
* Frames longer than `MAX_FRAME` are cut: the IP ends the delivered frame with `tuser` = 1 once
  `MAX_FRAME` bytes have arrived and discards the rest.

### 1.4 Parameters (common to every omac IP)

| Parameter | Description |
|---|---|
| `DATA_WIDTH` | AXI-Stream width in bits: 64 (`omac_10g`), 256 (`omac_40g`); a CMAC wrapper would use 512 |
| `MIN_FRAME` | minimum received frame length **including** the FCS (default 64); shorter frames get `tuser` = 1 |
| `MAX_FRAME` | maximum received frame length including the FCS (default 9600) |
| `PAUSE_EN` | 1: 802.3x PAUSE reception (timer) and transmission (`ctl_tx_pause_*`); 0: PAUSE frames are consumed and ignored, `ctl_tx_pause_send` is ignored |

Each IP adds its own parameters (see its page).

### 1.5 Control bundle (`ctl_*`, inputs, levels in `clk`)

All control inputs are **levels**, synchronous to `clk` (except where the table says they are
also used in the receive clock). None of them is a pulse or a command; the IP has no internal
control register.

| Port | Width | Description |
|---|---|---|
| `ctl_tx_enable` | 1 | 1: frames are started on transmit; 0: idles are sent after the current frame, `tready` low. **PAUSE frames are not started either while 0** (a pending XOFF or XON waits) |
| `ctl_rx_enable` | 1 | 1: received frames are delivered; 0: frames that start while 0 are dropped (1.3). Synchronised into the receive clock and sampled at each frame start. Received PAUSE frames act regardless of it |
| `ctl_loopback` | 1 | 1: near-end loopback inside the transceiver (64B/66B IPs drive `gt_loopback`; see 2.4). The far end receives the transmit stream as usual |
| `ctl_tx_fault` | 1 | 1: transmit continuous **Local Fault** ordered sets instead of data (test and shutdown use; the far end answers with Remote Fault). It overrides everything else on the wire: frames, PAUSE frames and our own Remote Fault |
| `ctl_pause_tx_honour` | 1 | 1: the IP itself does not start new frames while `stat_rx_pause_req` = 1 (PAUSE frames it must send still go out). 0: the user honours `stat_rx_pause_req` (or ignores PAUSE) |
| `ctl_tx_pause_send` | 1 | **level PAUSE request**: on the rising edge an XOFF PAUSE frame (`pause_time` = `ctl_tx_pause_quanta`) is sent ahead of the next data frame; while it stays high the XOFF is repeated every `ctl_tx_pause_refresh` quanta (counted from the start of the previous XOFF); on the falling edge one XON (`pause_time` 0) is sent. One request is pending at a time: an edge that comes before the previous request went out replaces it (a short high pulse becomes a single XON). Ignored when `PAUSE_EN` = 0 |
| `ctl_tx_pause_quanta` | 16 | `pause_time` of the XOFF frames, in quanta of 512 bit times; latched when a PAUSE frame starts |
| `ctl_tx_pause_refresh` | 16 | XOFF repeat interval in quanta (0 = no repeat); loaded when an XOFF frame starts. Choose it below `ctl_tx_pause_quanta` (half is usual) so the far end's timer never runs out while the request is high |
| `ctl_mac_addr` | 48 | the station address: source address of the PAUSE frames sent (latched when a PAUSE frame starts), and the unicast destination accepted for received PAUSE frames (besides 01-80-C2-00-00-01; used unsynchronised in the receive clock). Byte 0 on the wire = bits [7:0] (same byte order as `tdata`). Quasi-static: change it only while `ctl_rx_enable` = 0 |

#### 1.5.1 Control inputs: software rules

"Reset" is the value the design's register should take at its own reset (the IP itself has no
reset value for an input). Each rule is what the RTL does; a design that applies them is
referenced in [6.5](#65-worked-example).

| Port | Register reset | When software may change it | If misused |
|---|---|---|---|
| `ctl_tx_enable` | 0 | any time; it takes effect at the next frame boundary (a frame in progress completes). Set it after the station address and the PAUSE values are written, so the first PAUSE frame carries them. Setting it before the transceiver is ready or while `rst` is high is harmless (the TX side is in reset; frames sent before the link is up are discarded on the wire) | left at 0: nothing is sent, not even PAUSE; the TX source sees `tready` = 0 for ever |
| `ctl_rx_enable` | 0 | any time; a frame being received when it falls still completes. Set it after `ctl_mac_addr` | `ctl_mac_addr` changed while it is 1: a PAUSE frame arriving at that moment can be mis-filtered |
| `ctl_loopback` | 0 | any time, but **it is a link event**: the receiver switches between the partner's signal and its own transmitter, loses lock and locks again, so `stat_link_up` drops and frames in flight are lost in both directions. Treat every change as a relink (wait for `stat_link_up` again, re-snapshot the counters). While it is 1 the partner still receives everything we send, including the loopback test traffic, and nothing the partner sends reaches us | switching it during traffic: lost frames (counted as FCS / bad-block errors at both ends) |
| `ctl_tx_fault` | 0 | any time (a test or "port administratively down" control) | left at 1: the partner never gets a link (it receives Local Fault), our `stat_remote_fault` = 1 and `stat_link_up` = 0; frames are still accepted and discarded |
| `ctl_pause_tx_honour` | design choice, usually static | any time; checked at each frame boundary | 0 while nothing else honours `stat_rx_pause_req`: received PAUSE frames are counted but have no effect |
| `ctl_tx_pause_send` | 0 | normally driven by **hardware** (a receive FIFO level with hysteresis), not by software; software only enables or disables that path (an AND gate in the design) | held high for ever: the partner stays paused (XOFF repeated every refresh interval) until it falls; with refresh 0 the partner resumes after one `ctl_tx_pause_quanta` although the request is still high |
| `ctl_tx_pause_quanta` | design choice (0x100 was used on hardware at 40G) | any time; the next PAUSE frame takes the new value | 0: every "XOFF" is an XON (no flow control) |
| `ctl_tx_pause_refresh` | design choice (0x80 with quanta 0x100) | any time; loaded at the next XOFF | at or above `ctl_tx_pause_quanta`: the partner's timer runs out between XOFFs and it resumes in bursts |
| `ctl_mac_addr` | the design's station address | only while `ctl_rx_enable` = 0 (quasi-static, crosses into the receive clock without a synchroniser) | see `ctl_rx_enable` |

Remote fault behaviour is automatic (IEEE 802.3 clause 46.3.4, link fault signalling in the RS):
when the receiver sees Local Fault (from its own PCS: no block lock, high BER; or from the far
end), the IP transmits continuous **Remote Fault**; when it receives Remote Fault it transmits
**idles** (no frames go out); otherwise data flows. No control input is needed for this.

### 1.6 Status bundle (`stat_*`, outputs, levels in `clk`)

All status outputs are **levels** in `clk`. The ones made in the receive clock reach `clk`
through two-flop synchronisers (2-3 `clk` cycles of delay); `stat_link_up` is registered once
more. They are frozen while `clk` is stopped (transceiver in reset or without a reference clock).

| Port | Width | Value in reset | Description |
|---|---|---|---|
| `stat_link_up` | 1 | 0 | `stat_block_lock && !stat_hi_ber && !stat_local_fault && !stat_remote_fault && gt_tx_ready` (registered). Use it as the link input of the logic behind the MAC and as the one "link" bit of the design's registers. See 1.6.1 for what it does and does not prove |
| `stat_block_lock` | 1 | 0 | 64B/66B block lock **and** `gt_rx_ready` (40G: all four lanes AM-locked, deskewed and aligned; the per-lane block lock is `stat_lane_block_lock`). A hard-MAC wrapper maps its "aligned" status |
| `stat_hi_ber` | 1 | 0 | high bit error ratio (clause 49.2.13: 16 or more invalid sync headers within 125 µs at 10G; 40G: 97 within 1.25 ms over the four lanes). Only evaluated while block lock is held: 0 without lock |
| `stat_local_fault` | 1 | 1 while `gt_rx_ready` = 0, else 0 | the RS link fault state is Local Fault (our receiver is not working: no lock, high BER, or the far end's PHY reports Local Fault), or the transceiver RX is not ready. After `rst` is released it reads 1 until the receiver has locked (our own PCS reports Local Fault until then) |
| `stat_remote_fault` | 1 | 0 | the RS link fault state is Remote Fault (the far end does not receive us) |
| `stat_rx_pause_req` | 1 | 0 | **level**: a received PAUSE timer is running (XOFF received, counting down `pause_time` x 512 bit times inside the IP; an XON clears it). The user's TX source must not start new frames while it is high, unless `ctl_pause_tx_honour` = 1 (the IP then holds `s_axis_tx_tready` itself). Never 1 with `PAUSE_EN` = 0. A consumer with its own pause-hold input takes this level and keeps `ctl_pause_tx_honour` = 0 (section 4) |
| `stat_rx_pause_quanta` | 16 | 0 | `pause_time` of the last valid PAUSE frame received (updated also with `PAUSE_EN` = 0) |
| `stat_tx_pause_active` | 1 | 0 | the transmit PAUSE request is in the XOFF state: set when the first XOFF frame of a `ctl_tx_pause_send` high period starts, cleared on the falling edge of `ctl_tx_pause_send` (its XON follows) |

#### 1.6.1 What `stat_link_up` means

`stat_link_up` = 1 means: the transceiver is ready in both directions, the receiver has block
lock (40G: all lanes aligned) without a high BER, it does not see Local Fault (from its own PCS
or from the far end's PHY), and it does not receive Remote Fault, i.e. **the far end reports
that it receives us**. Both directions therefore work at the PCS level. It does not prove that
frames get through: a receiver that has block lock but decodes every block as an error (for
example the wrong bit order or a P/N swap, see the IP pages) can show `stat_link_up` = 1 with
`ev_rx_bad_block` counting at the block rate. Judge a link by `stat_link_up` **and** the error
counters since link-up (6.3).

It falls within a few `clk` cycles of: loss of block lock (16 invalid sync headers within 64),
a high BER, a Local Fault or Remote Fault (4 fault ordered sets, a few cycles),
`rst`, or either transceiver ready going low. It rises again on its own when the cause goes away
(nothing has to be reset); the time is on the IP pages.

### 1.7 Event bundle (`ev_*`, outputs, one-cycle pulses in `clk`)

Each pulse counts one event. Events produced in the recovered clock are crossed into `clk`
without loss (a gray-coded event counter per event; the `clk` side replays the count, at most one
pulse per cycle). Feed them to counters (`common/omac_axil_stats` or the user's own); the IPs
count nothing themselves (6.3). All are 0 while the IP is in reset.

| Port | Event |
|---|---|
| `ev_tx_frame` | a frame was transmitted completely (user frames and PAUSE frames; aborted and underflowed frames are not counted). It also counts while the link is down: frames are then replaced by Remote Fault or idles on the wire (1.2), so a rising TX count is no proof of delivery |
| `ev_tx_pause` | a PAUSE frame (XOFF or XON) was transmitted |
| `ev_tx_underflow` | a frame was aborted because `tvalid` dropped inside it |
| `ev_tx_abort` | a frame was aborted by `tuser` |
| `ev_rx_frame_good` | a frame was delivered with `tuser` = 0 |
| `ev_rx_frame_bad` | a frame was delivered with `tuser` = 1, or dropped for having no bytes after the FCS (not: frames dropped while `ctl_rx_enable` = 0, MAC Control frames) |
| `ev_rx_fcs_error` | FCS error |
| `ev_rx_runt` | received frame shorter than `MIN_FRAME` (including FCS) |
| `ev_rx_oversize` | received frame longer than `MAX_FRAME` |
| `ev_rx_pause` | a valid PAUSE frame was received |
| `ev_rx_bad_block` | the PCS receive state machine output an error block (invalid sync header, invalid block type or control code, or a sequence error); clause 49 `errored_block_count`. It also counts while a link is being acquired: judge it from link-up on |
| `ev_rx_sequence_error` | the subset of `ev_rx_bad_block` where the block itself was valid but out of sequence (for example data without a start) |

The PAUSE frame contents are those of IEEE 802.3 annex 31B: destination 01-80-C2-00-00-01,
source `ctl_mac_addr`, EtherType 0x8808, opcode 0x0001, `pause_time` (big-endian), 42 zero
bytes, FCS (64 bytes on the wire).

## 2. GT side (per IP)

This part is defined for the 64B/66B IPs. The IP is transceiver-agnostic: it speaks IEEE bit
order and leaves the transceiver's conventions to the `gt/` wrapper of the family (for
UltraScale+ GTH: [](gt_usp_gth.md)).

### 2.1 66-bit block interface, one lane

| Port | Dir | Width | Clock | Description |
|---|---|---|---|---|
| `gt_tx_hdr` | out | 2 | `clk` | sync header of the block, **bit 0 transmitted first**: data block `2'b10` (bits 0,1 = "01" in clause 49 notation), control block `2'b01` |
| `gt_tx_data` | out | 64 | `clk` | scrambled block payload, **bit 0 transmitted first** (right after the header) |
| `gt_rx_clk` | in | 1 | - | the recovered user clock of the lane (GT `RXUSRCLK2`) |
| `gt_rx_valid` | in | 1 | `gt_rx_clk` | the block on `gt_rx_hdr`/`gt_rx_data` is valid (GT `RXDATAVALID[0]`; tie 1 if the transceiver has no gaps) |
| `gt_rx_hdr` | in | 2 | `gt_rx_clk` | received sync header, bit 0 first in time |
| `gt_rx_data` | in | 64 | `gt_rx_clk` | received scrambled payload, bit 0 first in time |
| `gt_rx_slip` | out | 1 | `gt_rx_clk` | one-cycle pulse: shift the receive block boundary by one bit (GT `RXGEARBOXSLIP`). The block lock state machine waits `SLIP_WAIT` cycles after each slip before it tests headers again |

One block is transferred on every `clk` cycle on transmit (no gaps: the transceiver's
**asynchronous** gearbox absorbs the 66/64 ratio). The 40G IP has four such lanes on one `clk`,
as packed vectors: transmit lane l = `gt_tx_hdr[2l +: 2]` / `gt_tx_data[64l +: 64]` (PCS lane
l), receive physical lane p = `gt_rx_clk[p]`, `gt_rx_valid[p]`, `gt_rx_hdr[2p +: 2]`,
`gt_rx_data[64p +: 64]`, `gt_rx_slip[p]`; each receive lane has its own recovered clock and the
lanes may arrive in any order (the IP reorders by alignment marker). `gt_tx_ready`,
`gt_rx_ready`, `gt_rx_reset_req` and `gt_loopback` are shared by the four lanes.

**Two ways to build the 66-bit interface:**

| Option | How | Used for |
|---|---|---|
| **GT gearbox (chosen for UltraScale+)** | the transceiver's built-in 64B/66B **asynchronous** gearbox: 64-bit data + 2-bit header per user clock at the block rate (10.3125 Gb/s / 66 = 156.25 MHz), `TXSEQUENCE` tied to 0, `RXGEARBOXSLIP` for block alignment, `RXDATAVALID`/`RXHEADERVALID` as qualifiers. No fabric gearbox, user clock = block clock, no gaps on transmit | `gt/omac_gt_usp_gth` (gtwizard_ultrascale "64B66B_ASYNC", the free IP) |
| Fabric gearbox | the transceiver in raw mode (32 or 64 bits per user clock at 10.3125/32 = 322.27 MHz or /64 = 161.13 MHz) and a 64:66 gearbox in fabric that produces one block on 32 of 33 cycles (a valid qualifier on both directions) and does the bit slip itself | transceivers without a 64B/66B gearbox (future `gt/` wrappers; not needed on UltraScale+) |

The UltraScale+ gearbox transmits **MSB first** (AMD's gtwizard example design states it and
bit-reverses its PRBS data); the GTH wrapper therefore reverses the 64 data bits and swaps the
two header bits in both directions, so that the IP keeps IEEE bit order. With that convention a
data block appears on the GT port `TXHEADER[1:0]` as `2'b01`.

### 2.2 Transceiver readiness and resets

| Port | Dir | Width | Clock | Description |
|---|---|---|---|---|
| `gt_tx_ready` | in | 1 | any (synchronised) | the transmit side of the transceiver is up: gtwizard `gtwiz_reset_tx_done_out && gtwiz_userclk_tx_active_out`. While 0 the TX side of the IP is in reset (`tready` = 0) |
| `gt_rx_ready` | in | 1 | any (synchronised) | the receive side is up: `gtwiz_reset_rx_done_out && gtwiz_userclk_rx_active_out`. While 0 the RX side of the IP (in `gt_rx_clk`) is in reset |
| `gt_rx_reset_req` | out | 1 | `clk` | 64-cycle pulse: the RX has had no block lock (or a high BER) for `RX_WATCHDOG` cycles; drive the transceiver's RX datapath reset (gtwizard `gtwiz_reset_rx_datapath_in`). Then the CDR and gearbox restart, which recovers links where the partner appeared after our reset. Repeats every `RX_WATCHDOG` cycles (13.4 ms by default) while the condition lasts; the count stops while `gt_rx_ready` = 0. 0 in `rst`. Software never needs to drive this reset itself |

The transceiver's own reset controller (gtwizard: free-running clock, `gtwiz_reset_all_in`) stays
in the wrapper; the design holds `gtwiz_reset_all_in` until the reference clock is stable (for
example, a programmable clock generator on the FMC must be programmed first), then releases it.

### 2.3 Clock conventions

* `clk` = transceiver TX user clock 2. The whole TX path (MAC, RS, PCS encoder, scrambler) and the
  whole user side run on it.
* `gt_rx_clk` = transceiver RX user clock 2 = the recovered clock. The PCS receive path (block
  lock, descrambler, decoder, BER monitor), the RS link fault detection and the MAC receive path
  run on it; frames cross to `clk` in an asynchronous FIFO (gray pointers), status levels in
  two-flop synchronisers, events in gray-coded event counters. omac_40g: per lane, block lock, AM
  lock and the BIP check run in the lane's `gt_rx_clk[p]`; the lanes cross into one of them
  (`RX_CLK_LANE`) through the per-lane deskew FIFOs, where the rest of the receive path runs.
* Constrain the clocks as asynchronous (`set_clock_groups -asynchronous`) or, stricter, with
  `set_max_delay -datapath_only` of one `clk` period on the paths into the synchronisers (cells
  with `ASYNC_REG`); the IP's page lists the constraint.

### 2.4 Loopback

| Port | Dir | Width | Description |
|---|---|---|---|
| `gt_loopback` | out | 3 | the transceiver's `LOOPBACK` port: `LOOPBACK_MODE` (default `3'b010`, near-end PMA) while `ctl_loopback` = 1, else `3'b000`. Registered from `ctl_loopback` (one `clk` cycle), not affected by `rst` |

Near-end loopback is done in the transceiver because a fabric loopback of the 66-bit stream
would have to move the receive path from the recovered clock to `clk` (a clock multiplexer).
Near-end PMA loopback (`3'b010`) exercises the whole IP plus the transceiver's gearbox and
serialiser; near-end PCS loopback (`3'b001`) can be selected by the parameter.

## 3. Optional: AXI-Lite statistics

`common/omac_axil_stats` is a separate block, not part of the boundary: an AXI4-Lite slave with
one 48-bit saturating counter per event input, a status word and a clear control (map in
[](common.md#omac_axil_stats-register-map)). Connect the `ev_*` pulses (and `stat_*` levels) of any
omac IP, or count them in the user's own register file.

## 4. Connecting a consumer

The logic behind the MAC (an RDMA engine, a packet recorder, a DMA into a network driver, a
traffic generator) connects to the user side as follows; the names on the left are roles, not
port names of a particular engine.

| Consumer side | omac port |
|---|---|
| datapath clock and width | `clk`; the consumer's stream width = the IP's `DATA_WIDTH` (64 for `omac_10g`, 256 for `omac_40g`), running on `clk` |
| receive stream input | `m_axis_rx_*`: no `tready`, gaps allowed, `tuser` = bad frame (1.3) |
| transmit stream output | `s_axis_tx_*`: store-and-forward, no gaps inside a frame; `s_axis_tx_tuser` = abort, tie 0 if the consumer never aborts (1.2) |
| link up | `stat_link_up` (1.6.1) |
| receive status / aligned | `stat_block_lock` |
| PAUSE hold (level: do not start new frames) | `stat_rx_pause_req`, with `ctl_pause_tx_honour` = 0; or leave the hold to the IP with `ctl_pause_tx_honour` = 1 |
| received PAUSE quanta, for a consumer that times them itself | not needed: the IP times the quanta; use the consumer's level mode and tie its quanta inputs to 0 |
| PAUSE request (level, for example its receive FIFO above a high mark, released below a low mark) | `ctl_tx_pause_send`, with the XOFF quanta and refresh in `ctl_tx_pause_quanta` / `ctl_tx_pause_refresh` |
| PAUSE frame counts | `ev_rx_pause` / `ev_tx_pause` |
| MAC reset or FEC counter inputs meant for a hard MAC | tie 0 (the IPs have no FEC) |

A consumer such as an RDMA engine therefore maps `stat_rx_pause_req` to its pause-hold input
and drives `ctl_tx_pause_send` from its own receive FIFO level. A complete mapping, with the
registers of a real design, is referenced in [6.5](#65-worked-example).

## 5. Implementations of the boundary

| IP | `DATA_WIDTH` | `clk` | GT side | Status |
|---|---|---|---|---|
| `omac_10g` | 64 | 156.25 MHz (10GBASE-R), 390.625 MHz (25GBASE-R, `SPEED` = 25) | one lane, 2.1 | v0.1.0; 10GBASE-R hardware-proven, 25GBASE-R simulation + implementation |
| `omac_40g` | 256 | 156.25 MHz | four lanes (40GBASE-R4), 2.1 as packed vectors | v0.1.0, hardware-proven |
| CMAC wrapper | 512 | 322.27 MHz | none (hard MAC) | not in this repository; the mapping is direct (`rx_axis_*` without tready, `stat_rx_aligned` → `stat_block_lock`, `stat_rx_pause_req[8]` → `stat_rx_pause_req`, `ctl_tx_pause_req[8]` ← `ctl_tx_pause_send`) |

## 6. Software contract

The repository ships **no driver**: the IPs have no register block (no AXI-Lite slave), and there
is no Linux netdev driver and no bare-metal library. Each omac IP is controlled through the static
levels `ctl_*` and observed through the levels `stat_*` and the one-cycle pulses `ev_*`; **the
design around the MAC folds them into its own register block**, and its software drives them
through that block. Why:

* every design puts something different behind the MAC (a RoCE engine, a packet recorder, a DMA
  into a Linux netdev, a traffic generator) with its own register map, interrupt controller,
  clocking and software stack; a fixed MAC register block would be a second register map and a
  second clock-domain problem in every one of them;
* the control set is small and static (six control bits, the station address and two PAUSE
  values), so the register glue is a few lines of RTL;
* the boundary is the same for every omac IP and for a hard-MAC wrapper, so software written
  against the design's registers survives a MAC swap.

This section says what the register glue must expose and what software does with it. The
bring-up sequence, its timing, link-loss handling, loopback, PAUSE and the debug order of each IP
are on the IP pages ([](omac_10g.md#bring-up-and-software),
[](omac_40g.md#bring-up-and-software)); the transceiver resets on
[](gt_usp_gth.md#resets-and-handshake-software-view).

### 6.1 Clock domains: keep the registers reachable

`clk` is the transceiver's TX user clock. It **stops** while the transceiver is held in reset
(`reset_all`), until the reference clock runs, and when the reference clock is lost. Every
`stat_*` and `ev_*` output, and every register clocked by `clk`, is then frozen, and a bus access
to a register block clocked by `clk` does not complete (on an Arm processor: a hang, or an SError
if the interconnect answers with an error). Hence:

* keep the transceiver and MAC resets, the transceiver readiness bits and at least
  `stat_link_up` in a register block on a clock that never stops (the processor's register-bus
  clock), with a two-flop synchroniser (`ASYNC_REG`) per status level and gray-coded crossings
  for counters;
* reach any register in `clk` (including `omac_axil_stats`) only through a guard that answers
  every access, also while `clk` is stopped, or check a "MAC clock alive" bit in the always-on
  block before each access. An AXI clock converter alone does not help: it waits for the
  stopped side;
* the single-bit `ctl_*` written from another clock need a synchroniser each (they are levels);
  `ctl_mac_addr`, `ctl_tx_pause_quanta` and `ctl_tx_pause_refresh` may cross as quasi-static
  values (write them while they are not in use: before enabling RX / PAUSE).

### 6.2 Register set

**Minimum** (what a design should expose for its software to bring a link up and tell why it is
down):

| Item | Dir | From / to | Why |
|---|---|---|---|
| transceiver reset (wrapper `reset_all`) | W, reset 1 | GT wrapper | held until the reference clock has been programmed and is stable, then released once |
| MAC reset (`rst`) | W, reset 1 | IP | holds the IP while it is configured; a "relink" control |
| `ctl_tx_enable`, `ctl_rx_enable` | W, reset 0 | IP | |
| `ctl_mac_addr` | W | IP | needed when PAUSE is used (else tie it to a constant) |
| `gt_powergood`, `gt_tx_ready`, `gt_rx_ready` | R | GT wrapper | reference clock and transceiver diagnosis |
| a "MAC clock alive" indication | R | design (a heartbeat or frequency meter of `clk` in the always-on clock) | tells software whether `clk` registers are reachable |
| `stat_link_up` | R | IP | the link |
| `stat_block_lock`, `stat_hi_ber`, `stat_local_fault`, `stat_remote_fault` | R | IP | why the link is down |
| link-change latch or link-down counter | R | design (edges of `stat_link_up`) | polling misses short drops |
| counters of `ev_rx_frame_good`, `ev_rx_frame_bad`, `ev_rx_fcs_error`, `ev_rx_bad_block`, `ev_tx_frame`, `ev_tx_underflow` | R | IP, counted by the design | traffic and error evidence |
| omac_40g: `stat_lane_block_lock`, `stat_lane_am_lock`, `stat_lane_map`, `stat_lane_skew`; counters of `ev_rx_bip_error[3:0]`, `ev_rx_skew_fail`, `ev_rx_overflow` | R | IP | per-lane bring-up and signal integrity |

**Optional:**

| Item | Use |
|---|---|
| `ctl_loopback` | self-test without a cable or partner |
| PAUSE: `ctl_tx_pause_quanta`, `ctl_tx_pause_refresh`; an enable ANDed into the design's own PAUSE request before `ctl_tx_pause_send`; a PAUSE-honour enable (for `ctl_pause_tx_honour` or the design's TX scheduler); `stat_rx_pause_req`, `stat_tx_pause_active`, `stat_rx_pause_quanta`; counters of `ev_rx_pause`, `ev_tx_pause` | 802.3x flow control |
| `ctl_tx_fault` | testing the partner's fault handling, "administratively down" |
| counters of `ev_tx_pause`, `ev_tx_abort`, `ev_rx_runt`, `ev_rx_oversize`, `ev_rx_sequence_error` | finer error statistics |
| a count of `gt_rx_reset_req` pulses | shows that the RX watchdog is searching for a partner |

Tie-offs for what is not exported: `ctl_tx_fault` 0, `ctl_loopback` 0, `ctl_tx_pause_send` 0,
`ctl_pause_tx_honour` 0 or 1, `ctl_tx_pause_quanta` / `ctl_tx_pause_refresh` any constant.

### 6.3 Counters

The IPs count nothing. Each `ev_*` is a one-cycle pulse in `clk` (at most one per cycle; 40G
`ev_rx_bip_error` one bit per lane). Two ways to count them:

* `common/omac_axil_stats` ([map](common.md#omac_axil_stats-register-map)): one **48-bit
  saturating** counter per event, **no clear-on-read**; the only clear is `CTRL` bit 0, which
  clears all counters at once. Read `CNT_LO[i]`, then `CNT_HI[i]` (the low read latches the high
  half; there is one latch for the block, so two software readers must not interleave). At the
  highest frame rate (40G, 64-byte frames, 59.5 Mframes/s) a counter saturates after 54 days, at
  10G after 219 days; an event that fires on every cycle (bad blocks on a broken 40G link) after
  21 days. A counter at all ones means "at least that many".
* the design's own counters, of any width. For example: free-running 16-bit counters in `clk`,
  crossed gray-coded into the always-on clock and accumulated there into 32-bit **wrapping**
  counters that a write clears; software takes differences modulo 2^32.

Either way, the errors counted while a link is acquired (`ev_rx_bad_block`, `ev_rx_bip_error`,
`ev_rx_skew_fail`, the FCS error of a frame cut by the link going up or down) are not errors of
the running link: **snapshot or clear the counters at every link-up** and judge the link by the
counts since then.

### 6.4 Interrupt-worthy events

Latch these in the always-on block (a sticky status bit with write-1-to-clear and a mask, as
usual); the status levels themselves are not good interrupt sources (they stay set while the
link is down).

| Event | Source | Latch on | Software reaction |
|---|---|---|---|
| link change | `stat_link_up` | both edges | down: note the cause (`stat_block_lock`, `stat_hi_ber`, faults), hold the upper layers if they care (frames sent while down are discarded, 1.2); nothing has to be reset, the IP recovers by itself. Up: snapshot the counters, resume |
| transceiver lost | `gt_tx_ready` or `gt_rx_ready` | falling edge | `clk` registers are unreachable; check the reference clock (program it again if it was lost), then pulse `reset_all` |
| transmit underflow | `ev_tx_underflow` | any pulse | a design bug: the TX source left a gap inside a frame (it must be store-and-forward, 1.2) |
| receive overflow (omac_40g) | `ev_rx_overflow` | any pulse | frames were cut or dropped: the traffic mix exceeds the 256-bit limit ([](omac_40g.md#receive-path)) |
| high BER | `stat_hi_ber` | rising edge | signal integrity (the link is down while it is set) |

FCS errors, bad blocks and BIP errors are better polled as counters and judged by rate than
taken as one interrupt per event; `ev_rx_pause` / `ev_tx_pause` are counted, not interrupts.

### 6.5 Worked example

A design that implements this contract in full (an always-on block in the processor's register
clock that also guards every access into the MAC clock, the MAC-clock registers of its engine,
the counters, and the bring-up code shared by its bare-metal and Linux software) is described,
port by port, on the [projects page](projects.md).

## Change log

| Date | Change |
|---|---|
| 2026-11-03 | draft 1 |
| 2026-11-03 | section 4: the consumer mapping updated to level PAUSE hold / request and a receive status input |
| 2026-11-03 | draft 2 (omac_40g): start alignment per IP (1.2), wide-IP line rate note (1.3), four-lane GT side as packed vectors (2.1), section 5 status. No port of omac_10g changed |
| v0.1.0 | frozen as draft 2; section 3: the statistics counters are 48 bits (the text said 64); no port changed |
| v0.1.0 (2026-11-05) | documentation only, no port or behaviour changed: section 6 (software contract: no driver by design, clock domains, register set, counters, interrupts, a worked example); per-port software rules (1.5.1), value in reset (1.6), what `stat_link_up` means (1.6.1). Corrected against the RTL: frames dropped while `ctl_rx_enable` = 0 are **not** counted in `ev_rx_frame_bad` (the text said they were); PAUSE frames are not sent while `ctl_tx_enable` = 0 and are acted on while `ctl_rx_enable` = 0. Section 4 is now the generic consumer mapping; the mapping of one engine and the worked example of 6.5 are on the projects page |
