# Roadmap

Planned work, in no particular order and without dates. Contributions are welcome (pull
requests on [GitHub](https://github.com/fpgadeveloper/opsero-ethernet-mac)).

| Item | What it adds |
|---|---|
| **`omac_1g`** | 1000BASE-X / SGMII MAC + PCS (8B/10B, auto-negotiation for SGMII) behind the same boundary, for 1 GbE ports and SFP modules |
| **`omac_100g`** | 100GBASE-R4 MAC + PCS (four 25.78125 Gb/s lanes, 20 PCS lanes, RS-FEC) with a 512-bit user side, for devices without a hard 100G MAC or where a soft MAC is preferred |
| **25GBASE-R validation** | `omac_10g` with `SPEED` = 25 is simulated and closes timing at 390.625 MHz; it needs the GTY wrapper and a hardware run against a 25G partner |
| **`omac_gt_usp_gty`** | UltraScale+ GTY: `omac_gt_usp_gty_quad` (independent 10G lanes) exists (v0.2.0-dev); still to do: a 25.78125 Gb/s configuration for `SPEED` = 25 and a four-lane bonded wrapper for omac_40g |
| **RS-FEC** | clause 108 RS-FEC for 25GBASE-R and clause 91 for 100GBASE-R4 (many 25G partners and cables expect it) |
| **Versal** | transceiver wrappers for the Versal GTY / GTYP transceivers |
| **USXGMII on hardware** | `omac_10g` with `USXGMII_EN` = 1 is simulated against a PHY model and IP against IP ([](usxgmii.md)); it needs a run against a real USXGMII PHY and a check of the open protocol items against the single-port specification |
| omac_40g at full line rate for every frame size | a 512-bit or straddled user interface to remove the limit on back-to-back frames 1-7 bytes past a multiple of 32 ([](omac_40g.md#receive-path)) |
| Smaller omac_40g transmit path | the column packer is 6.6k LUT; a narrower packer or a straddled interface could reduce it |

Not on the list yet: clause 73 auto-negotiation and link training (point-to-point links with
both ends forced to the line rate work without them), clause 74 BASE-R FEC, EEE.
