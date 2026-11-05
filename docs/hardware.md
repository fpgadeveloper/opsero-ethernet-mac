# Hardware validation

`omac_40g`, `omac_10g` (at 10GBASE-R) and the GTH wrappers have been run on hardware against an
NVIDIA ConnectX-6 Dx. The setup, the measured link-up times, the RoCE v2 throughput, the PAUSE
behaviour and the error counts are in the section of the design that ran them on the
[projects page](projects.md#measured-on-hardware).

## omac_40g (40GBASE-CR4)

| Item | Result |
|---|---|
| Board, transceivers | AMD ZCU106 (XCZU7EV-2), four GTH channels of one quad, 156.25 MHz reference clock |
| Link partner, cable | ConnectX-6 Dx forced to 40000, auto-negotiation off, FEC off; 3 m passive QSFP28 DAC |
| Version, date | omac v0.1.0, November 2026 |
| Link | on the first power-up, within 6 s of the MAC reset release (dominated by the partner's own link-up); identity lane map from the partner, 0-1 block of skew |
| Traffic | line rate in both directions (RoCE v2, 38.7-39.2 Gb/s payload); 85.9 million frames with 0 FCS, errored-block, BIP or overflow errors |
| PAUSE | both directions: every transmitted XOFF honoured by the partner, received PAUSE held the transmit with no frame lost |
| Near-end PMA loopback | works with the cable to the partner still connected |

## omac_10g (10GBASE-R)

| Item | Result |
|---|---|
| Board, transceiver | AMD ZCU106 (XCZU7EV-2), one GTH channel (QSFP lane 0) |
| Link partner, cable | ConnectX-6 Dx forced to `10000baseCR` (it uses QSFP lane 0), auto-negotiation off, FEC off; 3 m passive QSFP28 DAC |
| Version, date | omac v0.1.0, November 2026 |
| Link | on the first power-up, within 6 s of the MAC reset release |
| Traffic | line rate (RoCE v2, 9.4-9.8 Gb/s payload); 0 FCS errors, 0 errored blocks after link-up, 0 transmit underflows |
| Near-end PMA loopback | works |

PAUSE frames have not been exchanged on a 10G link (the PAUSE block is the same `omac_pause`
proven at 40G).

## GTH wrappers

`BIT_REVERSE` = 1 (the default), `CH_OF_LANE` and the per-lane RX clocking of
`omac_gt_usp_gth_x4` confirmed with both IPs (link, alignment and error-free traffic on the
first power-up).

## Not covered on hardware

* 25GBASE-R (`omac_10g` with `SPEED` = 25): needs the GTY wrapper.
* Link partners other than the ConnectX-6 Dx, optical modules, cables other than the passive
  3 m DAC.
* Other GTH quads and other boards, boards with lane polarity swaps.
