# Simulation

Vivado xsim testbenches with Python drivers and an independent Python reference model. Every
test is self-checking and ends in one PASS / FAIL line. The regression runs two instances of an
IP back to back through bit-level transceiver models (random 66-bit phase, gearbox slip latency,
error injection, lane skew and permutation, clocks 100 ppm apart, every receiver on its own
recovered clock), and decodes what goes over the wire with a Python model written from the
standard, not from the RTL.

## Running

```
make sim            # python3 -I sim/run_tests.py          full regression
make sim-quick      # python3 -I sim/run_tests.py --quick  smaller workloads
python3 -I sim/run_tests.py -k 10g                         # tests whose name contains "10g"
python3 -I ip/omac_10g/sim/test_omac_10g.py pause10 --seed 3   # one omac_10g test, one seed
python3 -I ip/omac_40g/sim/test_omac_40g.py perms rate          # omac_40g tests
```

The full regression takes about 16 minutes on one CPU core. It needs Vivado 2025.x (`xvlog`, `xelab`, `xsim` on the PATH, `VIVADO_SETTINGS` pointing at
`settings64.sh`, or a usual install location) and Python 3 (standard library only). Build
products go to `sim/build` (or `$SIM_BUILD`); each testbench is compiled once per configuration
and again when a source changes. The full log of every omac_10g run is kept in
`sim/build/omac_10g/<test>/xsim.log`.

## Interop vectors

Two IPs that agree with each other could still both be wrong. The regression therefore also
compares the RTL with values taken from IEEE 802.3 by hand, independently of the RTL and of
the Python model:

* **64B/66B blocks** (`pcs_units`): 12 XGMII columns (idle, start in lane 0 and 4, data,
  terminate in lanes 0, 3 and 7, Local Fault ordered set, Local Fault + idle, error, invalid
  control, misplaced terminate) against 66-bit blocks written down from figure 49-7, and the
  first scrambled idle block from a zero scrambler state, 0x78000F000000001E, computed by hand.
* **40GBASE-R alignment markers and BIP** (`40g_units`): the markers of PCS lanes 0-3 against
  table 82-3, BIP3 of idle, data and marker blocks worked out bit by bit from table 82-4, and the
  second marker of lane 0 after 16383 idle blocks, 0xE1B8896F1E477690 (BIP3 0x1E).
* **CRC-32** (`crc32`): `omac_crc32` against `zlib.crc32`, the check value of "123456789"
  (0xCBF43926) and the residue 0xDEBB20E3.
* **PAUSE frames** (`10g_pause*`, `40g_pause`): destination, source, EtherType 0x8808, opcode,
  `pause_time` and padding of the frames on the wire, decoded by the Python model (annex 31B).

On hardware the same IPs interoperate with an NVIDIA ConnectX-6 Dx at 10GBASE-R and
40GBASE-R4 ([](hardware.md)).

## Files

| File | What it is |
|---|---|
| `omac_ref.py` | Python reference model written from IEEE 802.3, independent of the RTL: FCS (zlib), bit-serial descrambler, 66-bit block decoder (figure 49-7), XGMII frame parser (preamble, SFD, start lane, FCS, inter-packet gaps), PAUSE fields, frame files; **40GBASE-R**: marker table (table 82-3), BIP3 from table 82-4 written out bit by bit, a four-lane decoder (markers found on lanes in any order and skew, period and BIP3/BIP7 checked, deskew, reorder, marker removal, aggregate descrambling, clause 82 block subset, XLGMII frames starting on 8-byte columns, gaps) |
| `simlib.py` | file lists and the xsim runner |
| `tb_util.svh` | hex string helpers for the testbenches |
| `run_tests.py` | the regression |
| `ip/omac_10g/sim/tb_omac_10g.sv` | two omac_10g back to back, clocks 100 ppm apart, each receiver on the far end's TX clock; TX drivers, RX monitors, wire capture, mode sequences |
| `ip/omac_10g/sim/tb_gt_chan.sv` | bit-level channel + gearbox model: random 66-bit phase, slip with a 2-24 cycle latency, header / payload error injection (also one per omac_40g lane) |
| `ip/omac_40g/sim/tb_omac_40g.sv` | two omac_40g back to back, four lanes each way: block delay per lane (skew), lane permutation, `tb_gt_chan` per lane, every receiver lane on its own recovered clock (the far end's TX clock with a random phase), A and B 100 ppm apart; capture of the four lanes as the receiver sees them |
| `ip/omac_40g/sim/tb_40g_units.sv` | 40GBASE-R units: hand-computed marker / BIP vectors, pcs_tx marker insertion and stall, lane receivers (AM lock, lane number, BIP errors, marker loss), CRC-32 identities of the 256-bit MAC |

## Tests

| Test | Testbench / driver | What is checked |
|---|---|---|
| `bd_wrapper` | `scripts/gen_bd_wrapper.py --check` | `omac_10g_bd.v` matches `omac_10g.sv` |
| `ref_model` | `omac_ref.py` | the model's own vectors (hand-computed scrambled idle block, a T3 block, the CRC-32 check value) |
| `crc32` | `tb_crc32.sv` / `test_crc32.py` | `omac_crc32` at 8 and 32 bytes per word against `zlib.crc32`: 400 random frames (every last-word size, garbage above `nbytes`), "123456789" → 0xCBF43926, frame + FCS → residue 0xDEBB20E3 |
| `pcs_units` | `tb_pcs_units.sv` | **interop vectors**: 12 XGMII columns encoded and compared with 66-bit blocks written down by hand from figure 49-7 (idle, S0, data, T0, T3, T7, S4, LF 0x55, LF + idle 0x4B, error, invalid control, misplaced /T/), the first scrambled idle block from a zero state computed by hand (0x78000F000000001E); 4000 random encode → decode round trips of every block format; the scrambler against a bit-serial LFSR model; the descrambler self-synchronising from another state |
| `axil_stats` | `tb_axil_stats.sv` | ID / NCNT / STATUS, random events counted exactly, clear |
| `10g_frames`, `10g_frames_s2` | `test_omac_10g.py frames` | block lock + link up from random phases (through the slip path) in both directions; 300 frames each way (1-9000 bytes, 150 back to back), every frame exact (padding to 60 bytes, FCS stripped, `tkeep` contiguous, nothing lost); event counts; **A's wire stream decoded by the Python model**: no invalid block, preamble, SFD, /T/ and FCS of every frame, contents, starts in lane 0 or 4, every gap >= 9 bytes and the deficit idle count (sum of n gaps >= 12 n - 3) |
| `10g_errors` | `test_omac_10g.py errors` | TX aborts (`tuser`) and underflows (`tvalid` dropped) → exactly those frames bad at the far end, `ev_tx_abort` / `ev_tx_underflow` counts; one line bit flip in 250 frames B → A → exactly those frames bad (FCS), every other frame exact |
| `10g_runt` | `test_omac_10g.py runt` | A without padding sends runts, B with `MAX_FRAME` 1518 receives oversize frames: runts delivered with `tuser`, oversize frames cut at <= 1518 bytes with `tuser`, the event counts |
| `10g_pause10`, `10g_pause25` | `test_omac_10g.py pause10/25` | at 10G (6.4 ns) and 25G (2.56 ns): XOFF 100 quanta → `stat_rx_pause_req` 800 cycles (5.12 µs / 2.048 µs), XOFF 65535 cancelled by XON after 2000 cycles, XOFF refreshed every 100 quanta held one continuous period, B honouring PAUSE (`ctl_pause_tx_honour`: no frame start while paused), the PAUSE frames on the wire (DA, SA, 0x8808, opcode, `pause_time` sequence, 42 zero bytes, FCS), PAUSE frames consumed (none on B's AXI-Stream) |
| `10g_frames25` | `test_omac_10g.py frames25` | the frames test at `SPEED` 25 |
| `10g_fault` | `test_omac_10g.py fault` | B sends Local Fault → A local fault, link down, A transmits Remote Fault, B remote fault; A's receiver broken (all headers invalid) → A local fault from its own PCS, B in Remote Fault transmits idles while frames are offered; recovery of both |
| `10g_hiber` | `test_omac_10g.py hiber` | 1 bad header per 4000 blocks: no hi_ber; 1 per 150: hi_ber within a window, link down, local / remote fault, lock kept; errors off: hi_ber clears within 2 windows; 20 bad headers in a row: lock lost and re-acquired |
| `10g_watchdog` | `test_omac_10g.py watchdog` | no lock possible → `gt_rx_reset_req` pulses every `RX_WATCHDOG` cycles; the locked side does not pulse after locking |
| `10g_ts`, `10g_ts25` | `test_omac_10g.py ts / ts25` | **timestamp hooks** (`TS_EN` = 1, time values = cycle counters of each clock), 400 frames each way at 10G and at 25G: A's 402 transmit timestamps (400 user + 2 PAUSE) against the line of each frame's /S/ block in A's wire capture as decoded by the Python model (exact), `tx_ts_lane4` = the decoded start lane, `tx_ts_user` = 0 exactly for the PAUSE frames; every frame delivered at B / A carries a timestamp = the transmit timestamp of the same frame + 3 cycles (the channel latency, hand-computed from `tb_gt_chan`), the same lane-4 flag, constant on every beat; with aborts, underflows and oversize cuts (A->B, delivered bad), line bit flips (B->A, delivered bad), PAUSE frames consumed at B (no timestamp) and a third of the frames back to back at the minimum gap. Mutations (transmit sample one cycle early; lane-4 frames taking the SFD column's time) are caught |
| `40g_units` | `tb_40g_units.sv` | **interop vectors**: alignment markers of lanes 0-3 against 66-bit blocks written down by hand from table 82-3, BIP3 of idle / data / marker blocks worked out by hand from table 82-4, the 2nd and 4th marker of `omac_40g_pcs_tx` (scrambler off) after 16383 idle (BIP3 0x1E) or data (0x19) blocks; marker stall without block loss; lane receivers: AM lock, lane numbers, BIP errors, marker loss; 3000 CRC identity cases |
| `40g_frames`, `40g_frames_s2` | `test_omac_40g.py frames` | random lane permutation, skew and 66-bit phase per lane, per-lane recovered clocks; 600 frames each way (60-9000 bytes, half back to back) exact; the four lanes as received decoded by the Python model: lane ids, marker period, BIP3/BIP7, deskew, clause 82 blocks, frames, starts in lane 0 only, gaps >= 5 with the deficit idle count (every prefix sum >= 12 n - 7) |
| `40g_perms` | `test_omac_40g.py perms` | all 24 lane orders in a random order with random skew: relock, lane map and measured skew, 25 frames each (600) exact |
| `40g_skew` | `test_omac_40g.py skew` | skew beyond `DESKEW_MAX`: no alignment, failed attempts counted, faults; back within: relock, frames exact |
| `40g_lanefail` | `test_omac_40g.py lanefail` | one lane dies: per-lane lock, local fault, Remote Fault sent; recovery |
| `40g_hiber` | `test_omac_40g.py hiber` | BER monitor over four lanes with the real 1.25 ms window |
| `40g_errors` | `test_omac_40g.py errors` | aborts / underflows -> exactly those frames bad; payload flips on one lane -> FCS and BIP errors |
| `40g_overflow` | `test_omac_40g.py overflow` | RX banks forced to look empty to the reader for 4000 cycles: frames cut or dropped, every delivered frame exact or flagged |
| `40g_runt` | `test_omac_40g.py runt` | runts (24-63 bytes) and oversize frames (`MAX_FRAME` 1518) |
| `40g_pause` | `test_omac_40g.py pause` | PAUSE at 40G (2 cycles per quantum), XON, refresh, honour, frame contents via the Python decoder |
| `40g_fault` | `test_omac_40g.py fault` | Local Fault -> Remote Fault, Remote Fault -> idles, recovery |
| `40g_rate` | `test_omac_40g.py rate` | 10,000 x 64-byte and 1,000 x 9,600-byte frames back to back: cycles vs line rate less markers, all received |
| `40g_watchdog` | `test_omac_40g.py watchdog` | no alignment -> `gt_rx_reset_req` |

## Results

Full regression (`make sim`), 2026-11-05, Vivado 2025.2 xsim, v0.2.0-dev (omac_10g with the
timestamp hooks): **PASS, 31 tests, 0 failed, 19 min** (the 29 tests of v0.1.0 unchanged, plus
`10g_ts` and `10g_ts25`). v0.1.0 (2026-11-03): PASS, 29 tests, 16 min. The omac_10g rows below are
from the first omac_10g run (counts unchanged since).

| Test | Result | Time (s) | Measured along the way |
|---|---|---:|---|
| `bd_wrapper` | PASS | 0 | |
| `ref_model` | PASS | 0 | |
| `crc32` | PASS | 23 | 403 frames at 8 and 32 bytes per word, 0 mismatches |
| `pcs_units` | PASS | 12 | 12 vectors, 4000 round trips, 300 scrambled words |
| `axil_stats` | PASS | 10 | |
| `10g_frames` | PASS | 16 | lock 9.7k cycles (25 / 37 slips); 300 + 300 frames exact; 300 decoded on the wire; 54 % lane-4 starts; IPG min 9 |
| `10g_frames_s2` | PASS | 16 | other phases / lengths |
| `10g_errors` | PASS | 11 | 21 aborts + 29 underflows → 50 bad frames exactly; 250 line flips → 250 bad frames, 250 FCS errors |
| `10g_runt` | PASS | 8 | runts and oversize frames flagged, counted |
| `10g_pause10` | PASS | 8 | XOFF 100 quanta → 800 cycles = 5.12 µs; XON after 2000 cycles → 2000; refreshed XOFF → one period of 9999 cycles; 0 frame starts at B while paused; 18 PAUSE frames, sequence 100, 0, 65535, 0, 200 x 13, 0 |
| `10g_pause25` | PASS | 8 | the same in cycles at 2.56 ns: 800 cycles = 2.048 µs (100 x 512 bit times at 25 Gb/s) |
| `10g_frames25` | PASS | 11 | |
| `10g_fault` | PASS | 7 | recovery after Local Fault 77 / 152 cycles; after the RX outage (relock) 13.7k cycles |
| `10g_hiber` | PASS | 9 | 18 bad headers in 3 windows: no hi_ber; 1 / 150 blocks: hi_ber after 3032 cycles; clear 35.7k cycles after the errors stop; burst: lock lost after 20 blocks |
| `10g_watchdog` | PASS | 6 | 3 reset requests in 3 periods at the unlocked side |
| `10g_ts` | PASS | 21 | 402 TX timestamps = the /S/ block line of the decoded capture (0 mismatches, 139 lane-4 starts, 2 PAUSE with user 0); 400 + 400 frames delivered, RX - TX = 3 cycles for every frame; 49 bad A->B (16 aborts, 17 underflows, 16 cuts), 104 line errors B->A |
| `10g_ts25` | PASS | 21 | the same at 2.56 ns |
| `40g_units` | PASS | 17 | 4 marker blocks and 4 BIP values by hand; 2nd marker after 16383 idles = 0xE1B8896F1E477690 (lane 0), after data blocks BIP3 0x19; 159,968 blocks through the marker stall, no loss; lane AM lock, 1 flip -> 1 BIP error, marker loss after 4; 3000 CRC cases |
| `40g_frames` | PASS | 46 | lanes [0, 2, 1, 3], skew 1/15/24/27 (measured spread 27): 600 + 600 frames exact; Python: 12 markers, 0 period / BIP / alignment errors, 600/600 frames, IPG min 5, mean 12.03 |
| `40g_frames_s2` | PASS | 44 | other order, skew, phases, lengths |
| `40g_perms` | PASS | 194 | 24/24 lane orders, relock each time, skew up to 29 blocks measured +-1, 600 frames exact |
| `40g_skew` | PASS | 20 | 38 blocks: no alignment for 12 periods (10 failed attempts); 28 blocks: relock, frames exact |
| `40g_lanefail` | PASS | 24 | lane 2 dead: lane lock 1011, local fault after 25 cycles, Remote Fault sent; back: link after 62k cycles |
| `40g_hiber` | PASS | 163 | 1 / 8000 blocks on one lane: no hi_ber; 1 / 150: hi_ber after 14.8k cycles; clear within 2 windows |
| `40g_errors` | PASS | 21 | 37 aborts + 32 underflows -> 69 bad frames exactly; 35 payload flips -> 35 FCS errors, BIP errors on that lane |
| `40g_overflow` | PASS | 18 | reader stalled 4000 cycles: 285/400 good and exact, 1 cut, 114 dropped, 115 overflow events, nothing corrupted |
| `40g_runt` | PASS | 17 | 53 runts (24-63 bytes) with `tuser`, 65 oversize cut at <= 1518 |
| `40g_pause` | PASS | 21 | XOFF 100 quanta = 200 cycles = 1.28 us; XON; refresh 9999 cycles; 0 starts while paused; 55 PAUSE frames decoded |
| `40g_fault` | PASS | 24 | LF -> RF (0x4B), RF -> idles, recovery |
| `40g_rate` | PASS | 175 | 10,000 x 64 B in 26,247 cycles, 1,000 x 9,600 B in 300,342 cycles (line rate less markers), all received, 0 overflows, gaps mean 11.9996 |
| `40g_watchdog` | PASS | 34 | 3 reset requests in 3 periods, none at the aligned side |
