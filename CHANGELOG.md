# Changelog

All notable changes to opsero-ethernet-mac. One tag series for the repository; versions follow
semantic versioning; `-dev` versions are work in progress, releases are tagged on `main`.

## v0.2.0-dev (work in progress on `dev`)

Work in progress; merged to `main` and tagged after hardware validation.

### Added

- **omac_10g timestamp hooks** (`TS_EN` = 1, `TS_W`): the start of every frame is time-stamped
  at the 64B/66B block boundary of the transceiver interface. Transmit: `tx_ts_valid` (one per
  frame, in transmit order, one cycle after the /S/ block was on `gt_tx_data`) with
  `tx_ts_val` = the user's `tx_ts_in` of that cycle, `tx_ts_lane4` and `tx_ts_user` (0 for the
  MAC's own PAUSE frames). Receive: `rx_ts_in` (in `gt_rx_clk`) sampled with the /S/ block on
  `gt_rx_data` travels through the RX clock-crossing FIFO with the frame (`m_axis_rx_ts`,
  `m_axis_rx_ts_lane4`, constant on every beat), so frames that are not delivered never show a
  timestamp and a delivered frame always carries its own. Reference plane, lane-4 offset
  (3.103 ns at 10G, 1.241 ns at 25G) and the transceiver latencies to the pins:
  docs/omac_10g.md "Timestamp hooks". `TS_EN` = 0 (default): outputs 0, no logic added
  (routed: same FF count as v0.1.0). Cost at `TS_W` = 32: +45 LUT, +22 LUTRAM, +336 FF; timing
  met at 156.25 MHz (+3.139 ns, xczu7ev-2) and 390.625 MHz (+0.212 ns, xcku5p-2).
- **gt/omac_gt_usp_gth_quad** + `omac_gen_gth_quad`: four channels of one quad as four
  independent `omac_10g` lanes (one QPLL0, one TX user clock, one RX user clock per lane) with a
  per-lane RX reset (`RXPMARESET` of that channel; `omac_gt_usp_gth_x4` resets all four lanes,
  which takes the other links down when one port has no signal), per-lane readiness, loopback,
  polarity and driver settings, QPLL / CDR lock status and the reference clock / 8
  (`refclk_mon`) for a frequency monitor. `omac_gen_gth` takes an optional list of extra
  gtwizard ports (default: none, the existing IPs are unchanged).
- **Verification:** regression tests `10g_ts` and `10g_ts25` (31 tests in all): every transmit
  timestamp against the position of its /S/ block in the wire capture decoded by the Python
  model (`omac_ref.parse_capture` now reports the line of each /S/), the start lane and the
  PAUSE flag; every receive timestamp = the transmit timestamp of the same frame + the channel
  latency hand-computed from `tb_gt_chan` (3 cycles), constant on every beat; aborts,
  underflows, line errors, oversize cuts, consumed PAUSE frames, back-to-back frames at the
  minimum gap; at 10G and 25G. OOC jobs `omac_10g_ts_zu7ev`, `omac_10g_ts_25g_ku5p` and
  `omac_10g_quad_gth_zu7ev` (four omac_10g with hooks on the quad wrapper; `synth_ooc.tcl`
  extra `gtquad`).

### Not yet validated

- The hooks and the quad wrapper on hardware (the first design to use them: an Opsero
  SyncE + PTP reference design for the quad SFP28 FMC on a ZCU106).

## v0.1.0 (2026-11-05)

First release: omac_10g and omac_40g with the UltraScale+ GTH wrappers, the shared interface
contract (frozen), the simulation regression and the documentation site.

### Validated on

ZCU106 (XCZU7EV-2) + Opsero 2x QSFP28 FMC (OP120), QSFP28 port 0, 3 m passive QSFP28 DAC to an
**NVIDIA ConnectX-6 Dx** (firmware 22.43.2566, forced speed, auto-negotiation off, FEC off), in the
qsfp28-fmc-rocelet reference design (release 0.5.0, rocelet v0.3.0):

- **omac_40g** (40GBASE-CR4): link on the first power-up (all four lanes, identity lane map,
  0-1 block skew); RoCE v2 payload 38.83 Gb/s FPGA WRITE with immediate, 38.74 host WRITE,
  39.20 SEND, 38.73 host READ (line rate also at PMTU 1024 / 512: 37.0 / 34.4); 85.9 M frames
  with 0 FCS, block, BIP or overflow errors; PAUSE transmit (174,494 frames honoured by the
  partner) and PAUSE receive (WRITE stream held from 38.78 to 23.89 Gb/s, 0 lost); near-end PMA
  loopback.
- **omac_10g** (10GBASE-R): link on the first power-up on QSFP lane 0; RoCE v2 payload
  9.44-9.80 Gb/s with 0 FCS errors and 0 errored blocks; near-end PMA loopback.
- `BIT_REVERSE` = 1 and the default `CH_OF_LANE` of the GTH wrappers confirmed; per-lane RX
  clocking of `omac_gt_usp_gth_x4` confirmed.

Details: docs/projects.md (summary: docs/hardware.md). Regression (`make sim`): PASS, 29 tests.

### Added

- **docs/interface.md**: the shared boundary contract of every omac IP (user side: one user
  clock, AXI-Stream TX with abort and the no-gap rule, AXI-Stream RX without `tready` and with
  a bad-frame `tuser`, FCS stripped / padding + FCS appended, `ctl_*` / `stat_*` / `ev_*`
  bundles, level PAUSE; GT side for the 64B/66B IPs; optional statistics).
- **omac_10g**: 10GBASE-R MAC + PCS, 64-bit AXI-Stream at 156.25 MHz; 25GBASE-R with
  `SPEED` = 25 (390.625 MHz, same logic). PCS: 64B/66B encoder/decoder (figure 49-7),
  scrambler, block lock with gearbox slip, BER monitor, receive state machine (figure 49-17).
  RS: link fault signalling (Local Fault → Remote Fault, Remote Fault → idles). MAC: preamble/SFD,
  /S/ in lane 0 or 4, deficit idle count, 60-byte padding, FCS, length checks, 802.3x PAUSE
  (timer inside, level output, XOFF/refresh/XON from a level request), MAC Control filtering,
  underflow/abort. RX clock crossing (async FIFO), loss-free event crossing, RX watchdog.
  `omac_10g_bd.v` wrapper for IP integrator.
- **omac_40g**: 40GBASE-R4 MAC + PCS, 256-bit AXI-Stream at 156.25 MHz, four lanes at
  10.3125 Gb/s. PCS (clause 82): 64B/66B with the clause 82 block subset, one scrambler over the
  aggregate stream, round-robin distribution, alignment markers every 16384 blocks per lane with
  BIP3 (tables 82-3 / 82-4; the transmit path holds one cycle per period instead of deleting
  idles), per-lane block lock and AM lock in each lane's recovered clock, BIP check, deskew up to
  `DESKEW_MAX` (32 blocks = 204.8 ns) with lane FIFO flush per attempt, lane reorder by marker
  (any physical order), marker removal, BER monitor over four lanes (97 / 1.25 ms), receive state
  machine with look-ahead. RS (clause 81): /S/ in any 8-byte column of a beat, deficit idle count
  0..7 (average gap 12 bytes), Local / Remote Fault ordered sets (0x4B). MAC: pad, FCS (32-byte
  CRC network with right-aligned last beat), length checks, PAUSE with 40G quanta (512 bit times
  = 2 cycles), MAC Control filtering, underflow/abort, re-alignment and FCS strip with up to two
  chunks per cycle into a two-bank clock crossing with overflow handling. Line rate measured in
  simulation (64-byte and 9600-byte frames back to back). `omac_40g_bd.v` wrapper.
- **common/**: `omac_pkg`, `omac_crc32` (any width), scrambler/descrambler, block lock, BER
  monitor (any number of headers per cycle), RS link fault, PAUSE timers and PAUSE frame source,
  synchronisers, gray event CDC, async FIFO (with write-side free count), optional
  `omac_axil_stats`.
- **omac_10g 25G timing**: transmit CRC and FCS merge in two stages, receive frame verdict two
  cycles after the end word (full-word CRC network, partial-word CRC registered): 390.625 MHz
  routed on xcku5p-2 with +0.28 ns (was -1.37 ns); 10G +2.79 ns on xczu7ev-2. One more cycle of
  latency each way.
- **gt/omac_gt_usp_gth**: gtwizard_ultrascale generator (GTH-10GBASE-R preset, 64B66B_ASYNC,
  64-bit user width; one channel or four of a quad) and wrappers `omac_gt_usp_gth` (one lane)
  and `omac_gt_usp_gth_x4` (four lanes, lane-to-channel map, shared TX user clock, one RX user
  clock per lane); board placement described generically (what a design determines for its
  board: channel sites in lane order, reference clock, lane map, polarity), with a worked
  example on the projects page.
- **Documentation**: Sphinx site in `docs/` for Read the Docs (omac.ethernetfmc.com, `make docs`):
  overview, interface contract, one page per IP and for the GTH wrappers (clock-constraint XDC that
  works in an implementation-only file, global synthesis of the gtwizard IP, per-lane RX clocks),
  omac_40g bring-up and debug order, simulation, resources, hardware validation, roadmap, and a
  projects page (docs/projects.md) with one section per design that uses the cores:
  qsfp28-fmc-rocelet (its IPs per target, the omac-to-rocelet port mapping, the register worked
  example, full-design resources and the measured hardware results); the generic pages link to it
  once and hold no project-specific material. The IP, wrapper, common and simulation pages moved
  from their directories into `docs/` (the directories keep a short README).
- **docs: software contract; no drivers by design.** The cores ship no driver (no register block in
  the IPs, no netdev, no bare-metal library); docs/interface.md section 6 says what a design's own
  registers must expose (minimum and optional set), the clock-domain rule (`clk` stops while the
  transceiver is in reset), counters, interrupt-worthy events and a generic consumer mapping
  (section 4), with a design's always-on block as the worked example on the projects page; per-port
  software rules and reset values; a "Bring-up and software" section per IP (sequence, measured
  link-up times, link loss, loopback, PAUSE, healthy status, debug order) and the resets /
  handshake of the GTH wrappers. Corrected against the RTL: frames dropped while `ctl_rx_enable` =
  0 are not counted in `ev_rx_frame_bad`; a wrong `BIT_REVERSE` or a P/N swap does not prevent
  block lock (it shows as errored blocks at 10G, as missing marker lock at 40G).
- **Verification**: xsim regression (29 tests: omac_10g, omac_40g incl. all 24 lane orders,
  skew limit, lane failure, line rate) with an independent Python reference model (also a
  four-lane 40GBASE-R decoder); OOC synthesis scripts (`scripts/run_synth.sh`, per IP).

### Known limitations

- Hardware: one board (ZCU106, GTH) and one link partner (ConnectX-6 Dx over a passive DAC);
  25GBASE-R not yet on hardware (needs a GTY wrapper); PAUSE frames not yet exchanged at 10G.
- No RS-FEC (25GBASE-R without FEC only), no BASE-R FEC (clause 74), no auto-negotiation /
  link training, no EEE.
- omac_40g: frames whose length without FCS is 1..7 bytes above a multiple of 32 cannot be sent
  or received at full line rate with a 256-bit one-frame-per-beat AXI-Stream at 40.0 Gb/s (the
  receiver buffers bursts and cuts or drops frames beyond that, never corrupting them).
- omac_40g: frames that start and end inside one 256-bit beat (23 bytes or less with FCS) are
  counted (`ev_rx_runt`, `ev_rx_frame_bad`) but not delivered; `ev_rx_bad_block` /
  `ev_rx_sequence_error` count beats (four blocks) with at least one such block, not blocks.
