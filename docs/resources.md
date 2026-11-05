# Resources and timing

Out-of-context results with Vivado 2025.2, measured with the repository's synthesis jobs
(`make synth`, `make synth-gt`, `make synth40`, `make synth40-gt`; job lists in
`ip/<ip>/synth/jobs*.txt`, runner `scripts/run_synth.sh`). The IP's `clk` and its receive
clock(s) are constrained at the same period as asynchronous clocks. LUT / FF figures are after
place and route where the WNS says "routed", else after synthesis. No IP uses block RAM: every
FIFO is LUTRAM.

## omac_10g

| Job | Part | Clock | LUT | LUTRAM | FF | BRAM | WNS |
|---|---|---|---:|---:|---:|---:|---:|
| omac_10g, defaults (10GBASE-R) | xczu7ev-ffvc1156-2-e | 156.25 MHz (6.4 ns) | 3,482 | 44 | 2,348 | 0 | **+2.789 ns** routed |
| omac_10g, `SPEED` = 25 (25GBASE-R) | xcku5p-ffvb676-2-e | 390.625 MHz (2.56 ns) | 3,607 | 44 | 2,355 | 0 | **+0.284 ns** routed |
| omac_10g, `PAUSE_EN` = 0 (before the 25G pipeline stages) | xczu7ev-ffvc1156-2-e | 156.25 MHz | 3,069 | 44 | 1,869 | 0 | +2.526 ns (synthesis) |
| omac_10g + omac_gt_usp_gth (gtwizard, one channel; before the 25G pipeline stages) | xczu7ev-ffvc1156-2-e | refclk 156.25 MHz, derived TX / RX user clocks | 3,343 | 44 | 2,199 | 0 | +2.379 ns (synthesis); 1 GTHE4_CHANNEL, 1 GTHE4_COMMON, 4 BUFG_GT |

On the ZU7EV the 10G IP is 1.4 % of the LUTs and 0.4 % of the registers. 25GBASE-R closes
timing at 390.625 MHz thanks to two pipeline stages (transmit CRC and FCS merge split, receive
frame verdict two cycles after the end word); before them the 25G build missed by 1.37 ns
(fmax about 255 MHz).

## omac_40g

| Job | Part | Clock | LUT | LUTRAM | FF | BRAM | WNS |
|---|---|---|---:|---:|---:|---:|---:|
| omac_40g, defaults | xczu7ev-ffvc1156-2-e | 156.25 MHz (6.4 ns) | 16,438 | 624 | 8,577 | 0 | **+1.573 ns** routed (WHS +0.007) |
| omac_40g, `PAUSE_EN` = 0 | xczu7ev-ffvc1156-2-e | 156.25 MHz | 16,497 | 624 | 8,459 | 0 | +3.296 ns (synthesis) |
| omac_40g + omac_gt_usp_gth_x4 (gtwizard, four channels of one quad) | xczu7ev-ffvc1156-2-e | refclk 156.25 MHz, derived TX / RX user clocks | 17,172 | 624 | 8,868 | 0 | +2.419 ns (synthesis); 4 GTHE4_CHANNEL, 1 GTHE4_COMMON, 10 BUFG_GT |

On the ZU7EV that is 7.1 % of the LUTs and 1.9 % of the registers. By block (synthesis): MAC TX
6.6k LUT (the column packer and the 256-bit FCS), PCS RX 3.9k (four decoders, descrambler,
state machine, deskew), MAC RX 2.2k, PCS TX 1.6k, four lane receivers with their lane FIFOs
1.0k, RX banks 0.6k. Worst routed path: the packer's gap / deficit-idle decision into the
column buffer (10 logic levels, +1.57 ns); worst receive path +1.70 ns (MAC RX end beat into
the bank write).

In the GTH jobs Vivado derives the TX and RX user clocks from the same QPLL and treats them as
related, which makes the synthesis hold figure of those jobs meaningless (-0.295 ns for the
four-lane job); in a design the receive clocks are recovered from the far end, so constrain the
crossings as described on [](gt_usp_gth.md#clock-constraints).

## In a full design

Figures of the cores routed inside a complete design (with its engine, processor system and
memory paths) are on the [projects page](projects.md).
