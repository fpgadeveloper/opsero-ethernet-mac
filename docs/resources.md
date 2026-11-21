# Resources and timing

Out-of-context results with Vivado 2025.2, measured with the repository's synthesis jobs
(`make synth`, `make synth-gt`, `make synth40`, `make synth40-gt`, `make synth-mdio`; job lists in
`ip/<ip>/synth/jobs*.txt`, runner `scripts/run_synth.sh`). The IP's `clk` and its receive
clock(s) are constrained at the same period as asynchronous clocks. LUT / FF figures are after
place and route where the WNS says "routed", else after synthesis. No IP uses block RAM: every
FIFO is LUTRAM.

## omac_10g

| Job | Part | Clock | LUT | LUTRAM | FF | BRAM | WNS |
|---|---|---|---:|---:|---:|---:|---:|
| omac_10g, defaults (10GBASE-R) | xczu7ev-ffvc1156-2-e | 156.25 MHz (6.4 ns) | 3,482 | 44 | 2,348 | 0 | **+2.789 ns** routed |
| omac_10g, `SPEED` = 25 (25GBASE-R) | xcku5p-ffvb676-2-e | 390.625 MHz (2.56 ns) | 3,607 | 44 | 2,355 | 0 | **+0.284 ns** routed |
| omac_10g, `TS_EN` = 1 (timestamp hooks, `TS_W` 32; v0.2.0-dev) | xczu7ev-ffvc1156-2-e | 156.25 MHz (6.4 ns) | 3,513 | 66 | 2,684 | 0 | **+3.139 ns** routed |
| omac_10g, `SPEED` = 25, `TS_EN` = 1 (v0.2.0-dev) | xcku5p-ffvb676-2-e | 390.625 MHz (2.56 ns) | 3,639 | 66 | 2,691 | 0 | **+0.212 ns** routed |
| omac_10g, `PAUSE_EN` = 0 (before the 25G pipeline stages) | xczu7ev-ffvc1156-2-e | 156.25 MHz | 3,069 | 44 | 1,869 | 0 | +2.526 ns (synthesis) |
| omac_10g + omac_gt_usp_gth (gtwizard, one channel; before the 25G pipeline stages) | xczu7ev-ffvc1156-2-e | refclk 156.25 MHz, derived TX / RX user clocks | 3,343 | 44 | 2,199 | 0 | +2.379 ns (synthesis); 1 GTHE4_CHANNEL, 1 GTHE4_COMMON, 4 BUFG_GT |
| 4 x omac_10g (`TS_EN` = 1, `TS_W` 16) + omac_gt_usp_gth_quad (gtwizard, four independent lanes of one quad; v0.2.0-dev) | xczu7ev-ffvc1156-2-e | refclk 156.25 MHz, derived TX / RX user clocks | 13,372 | 208 | 9,200 | 0 | **+1.749 ns** routed (WHS +0.011); 4 GTHE4_CHANNEL, 1 GTHE4_COMMON, 10 BUFG_GT (+1 when `refclk_mon` is used) |
| 2 x omac_10g (`TS_EN` = 1, `TS_W` 16) + omac_gt_usp_gty_quad (`NLANES` = 2, GTY, sites X0Y12 X0Y13; v0.2.0-dev, `make synth-gtq`) | xcku5p-ffvb676-2-e | refclk 156.25 MHz, derived TX / RX user clocks | 6,747 | 104 | 4,712 | 0 | **+1.755 ns** routed (WHS +0.013); 2 GTYE4_CHANNEL, 1 GTYE4_COMMON |
| 2 x omac_10g (`TS_EN` = 1, `TS_W` 16) + omac_gt_usp_gth_quad (`NLANES` = 2, GTH, sites X0Y14 X0Y13, `CH_OF_LANE` 0x01; v0.2.0-dev) | xczu7ev-ffvc1156-2-e | refclk 156.25 MHz, derived TX / RX user clocks | 6,750 | 104 | 4,712 | 0 | **+2.057 ns** routed (WHS +0.010); 2 GTHE4_CHANNEL, 1 GTHE4_COMMON |
| 4 x omac_10g (`TS_EN` = 1) + omac_gt_usp_gty_quad (`NLANES` = 4, sites X0Y8-X0Y11, `refclk` = `clk1`; v0.2.0-dev) | xcku5p-ffvb676-2-e | refclk 156.25 MHz | 13,753 | 208 | 10,028 | 0 | +2.381 ns (synthesis); 4 GTYE4_CHANNEL, 1 GTYE4_COMMON |
| 1 x omac_10g (`TS_EN` = 1) + omac_gt_usp_gty_quad (`NLANES` = 1, site X0Y13; v0.2.0-dev) | xcku5p-ffvb676-2-e | refclk 156.25 MHz | 3,570 | 52 | 2,674 | 0 | +2.381 ns (synthesis); 1 GTYE4_CHANNEL, 1 GTYE4_COMMON |

v0.2.0-dev rerun of the default job (`TS_EN` = 0): 3,468 LUT, 44 LUTRAM, 2,348 FF, +2.925 ns routed: the
register count of v0.1.0 exactly (the hooks add nothing when off; the LUT count moves with
place-and-route). On the ZU7EV the 10G IP is 1.4 % of the LUTs and 0.4 % of the registers. 25GBASE-R closes
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

## omac_mdio

The MDIO master on its AXI4-Lite clock `clk` (no other clock).

| Job | Part | Clock | LUT | LUTRAM | FF | BRAM | WNS |
|---|---|---|---:|---:|---:|---:|---:|
| omac_mdio, defaults | xczu7ev-ffvc1156-2-e | 100 MHz (10 ns) | 189 | 2 | 231 | 0 | **+7.391 ns** routed (WHS +0.051) |
| omac_mdio, `DIV_INIT` = 49 | xczu7ev-ffvc1156-2-e | 250 MHz (4 ns) | 190 | 2 | 231 | 0 | **+1.710 ns** routed (WHS +0.031) |
| omac_mdio, `DIV_INIT` = 49, `OPEN_DRAIN` = 1 | xczu7ev-ffvc1156-2-e | 250 MHz (4 ns) | 189 | 2 | 230 | 0 | **+1.586 ns** routed (WHS +0.042) |
| omac_mdio, defaults | xcvc1902-vsva2197-2MP-e-S | 100 MHz (10 ns) | 200 | 1 | 246 | 0 | **+7.184 ns** routed (WHS +0.038) |
| omac_mdio, `DIV_INIT` = 49 | xcvc1902-vsva2197-2MP-e-S | 250 MHz (4 ns) | 208 | 1 | 250 | 0 | **+1.429 ns** routed (WHS +0.038) |

The register block and the frame engine are a few hundred cells on any part; the worst path at
250 MHz is the frame engine's next-bit decision (state and bit counter into the MDIO output
bit or the bit counter), 2.3-2.5 ns.

## In a full design

Figures of the cores routed inside a complete design (with its engine, processor system and
memory paths) are on the [projects page](projects.md).
