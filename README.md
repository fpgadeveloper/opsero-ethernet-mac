# opsero-ethernet-mac

**opsero-ethernet-mac** is a collection of open-source Ethernet MAC + PCS cores for FPGAs,
written from scratch in vendor-neutral SystemVerilog (IEEE 802.3 clauses 46, 49, 81, 82 and
annex 31B) and released under the MIT license. Every core presents the same user-side
boundary - AXI-Stream transmit and receive on one user clock, FCS handled inside, PAUSE as
levels, a common status, control and event bundle - so a design can swap one MAC for another
(or for a hard MAC behind a thin wrapper) without touching the logic around it. The
transceiver is reached through a small per-family wrapper around the vendor's free
transceiver wizard; no licensed MAC, PCS or evaluation IP is involved.

The collection starts with `omac_10g` (10GBASE-R, 25GBASE-R by parameter) and `omac_40g`
(40GBASE-R4) with UltraScale+ GTH wrappers. The first user is
[rocelet](https://github.com/fpgadeveloper/rocelet), Opsero's open-source RoCE v2 engine, on
boards without a hard 100G MAC such as the ZCU106 with the Opsero 2x QSFP28 FMC.

The first release is being prepared on the `dev` branch; documentation will be published at
[omac.ethernetfmc.com](https://omac.ethernetfmc.com).

## License

MIT - Copyright (c) 2026 Opsero Electronic Design Inc.
