# opsero-ethernet-mac

**opsero-ethernet-mac** is a collection of open-source Ethernet MAC + PCS cores for FPGAs,
written from scratch in vendor-neutral SystemVerilog (IEEE 802.3 clauses 46, 49, 81, 82 and annex 31B)
and released under the MIT license. Every core presents the same user-side boundary - AXI-Stream
transmit and receive on one user clock, FCS handled inside, PAUSE as levels, a common status,
control and event bundle - so a design can swap one MAC for another (or for a hard MAC behind a
thin wrapper) without touching the logic around it. The transceiver is reached through a small
per-family wrapper around the vendor's free transceiver wizard; no licensed MAC, PCS or
evaluation IP is involved.

The cores are not tied to a board: any device with a supported transceiver wrapper (today
UltraScale+ GTH) can use them, and the board-specific part (which GT channels, which reference
clock) belongs to the design that instantiates them. The cores were validated on a ZCU106 with
the Opsero 2x QSFP28 FMC against an NVIDIA ConnectX-6 Dx. The collection was created for
Opsero's reference designs; the designs that use it are listed in
[docs/projects.md](docs/projects.md).

## IP cores

| IP | Standard | User side | Lane(s) | Maturity (v0.1.0) |
|---|---|---|---|---|
| [`omac_10g`](docs/omac_10g.md) | 10GBASE-R (25GBASE-R with `SPEED` = 25) | 64-bit AXI-Stream @ 156.25 MHz (390.625 MHz) | 1 x 10.3125 (25.78125) Gb/s | **10GBASE-R hardware-proven** (ZCU106 + ConnectX-6 Dx: link, RoCE v2 traffic at 9.4-9.8 Gb/s, 0 errors); 3.5k LUT, +2.8 ns at 156.25 MHz on xczu7ev-2. 25GBASE-R: simulated, routed at 390.625 MHz on xcku5p-2 (+0.28 ns), not yet on hardware |
| [`omac_40g`](docs/omac_40g.md) | 40GBASE-R4 (multi-lane distribution, alignment markers, BIP, deskew, lane reorder) | 256-bit AXI-Stream @ 156.25 MHz | 4 x 10.3125 Gb/s | **hardware-proven** (ZCU106 + ConnectX-6 Dx at 40GBASE-CR4: RoCE v2 at 38.7-39.2 Gb/s payload, PAUSE both ways, 0 FCS / block / BIP errors); 16.4k LUT, +1.57 ns at 156.25 MHz on xczu7ev-2 |
| `omac_1g` | 1000BASE-X / SGMII | 8-bit | 1 x 1.25 Gb/s | planned, no date |
| `omac_100g` | 100GBASE-R4 (RS-FEC) | 512-bit | 4 x 25.78125 Gb/s | planned, no date |

| Transceiver wrapper | Family | Maturity (v0.1.0) |
|---|---|---|
| [`gt/omac_gt_usp_gth`](docs/gt_usp_gth.md) | UltraScale+ GTH, 64B/66B asynchronous gearbox (gtwizard_ultrascale, free); one lane (`omac_gt_usp_gth`) or four (`omac_gt_usp_gth_x4`, per-lane RX clocks) | **hardware-proven** with both IPs (ZCU106; `BIT_REVERSE` = 1 confirmed) |
| `gt/omac_gt_usp_gty` | UltraScale+ GTY | planned |

The interface every IP implements is defined in [docs/interface.md](docs/interface.md). Hardware
validation details: [docs/hardware.md](docs/hardware.md); planned work: [docs/roadmap.md](docs/roadmap.md).

## Using it

The repository is meant to be pulled into a design as a git submodule. Each IP lists its sources
in compile order in `ip/<ip>/rtl/<ip>.f` (paths relative to the repository root), including the
`common/` blocks it needs:

```
git submodule add https://github.com/fpgadeveloper/opsero-ethernet-mac submodules/opsero-ethernet-mac
```

```tcl
# Vivado: read the source list
set omac submodules/opsero-ethernet-mac
foreach f [split [read [open $omac/ip/omac_10g/rtl/omac_10g.f]] "\n"] {
    if {$f ne "" && [string index $f 0] ne "#"} { read_verilog -sv $omac/$f }   ;# or add_files
}
# the transceiver: generate the free gtwizard IP and add the wrapper
source $omac/gt/omac_gt_usp_gth/gen_gt.tcl
omac_gen_gth ./ip <channel-site> 100        ;# the board's GT channel, for example X0Y14
read_verilog -sv $omac/gt/omac_gt_usp_gth/omac_gt_usp_gth.sv
```

The cores are driver-less by design: a design folds the MAC's static control and status ports
into its own register block, as described in the
[software contract](docs/interface.md#6-software-contract) (what to expose, bring-up, counters,
interrupts, a worked example).

When the design synthesises in memory (`synth_design`, no out-of-context IP runs), set the
generated gtwizard IP to global synthesis ([docs/gt_usp_gth.md](docs/gt_usp_gth.md)). In RTL,
instantiate `omac_10g` and `omac_gt_usp_gth` and connect the GT side (the IP page shows the
connection). In an IP integrator block design, add `ip/omac_10g/rtl/omac_10g_bd.v` (a
generated Verilog wrapper, needed because module references must have a Verilog top) as a module
reference; its AXI-Streams, clock and reset are recognised as interfaces. omac_40g works the same
way with `ip/omac_40g/rtl/omac_40g.f`, `omac_gen_gth_x4 ./ip` (four channels) and
`gt/omac_gt_usp_gth/omac_gt_usp_gth_x4.sv`, `omac_40g_bd.v` in a block design.

## Documentation

The documentation is hosted at [omac.ethernetfmc.com](https://omac.ethernetfmc.com) (built by
Read the Docs from the `docs/` folder, which reads the same on GitHub; `make docs` builds it
locally):

| Document | Contents |
|---|---|
| [docs/index.md](docs/index.md) | overview, IP and maturity tables, how to use the cores, bring-up checklist |
| [docs/interface.md](docs/interface.md) | the shared boundary contract: user side (mandatory), GT side, optional statistics, connecting a consumer, the software contract (no drivers by design) |
| [docs/omac_10g.md](docs/omac_10g.md) | omac_10g: architecture, bring-up and software (sequence, link-up time, link loss, loopback, PAUSE, debug order), parameters, timing and constraints, verification |
| [docs/omac_40g.md](docs/omac_40g.md) | omac_40g: architecture, throughput and its known limit, lane order and skew, board placement, bring-up and software (sequence, link-up time, link loss, loopback, PAUSE, debug order), parameters, timing |
| [docs/gt_usp_gth.md](docs/gt_usp_gth.md) | GTH wrappers (one and four lanes): generator scripts, global synthesis, clock constraints, resets and handshake (software view), gtwizard settings, bit order, RX clocking, board placement (what a design determines for its board) |
| [docs/common.md](docs/common.md) | the shared building blocks and the AXI-Lite statistics register map |
| [docs/simulation.md](docs/simulation.md) | the simulation regression, the interop vectors, the results |
| [docs/resources.md](docs/resources.md) | out-of-context resources and timing per IP, part and clock |
| [docs/hardware.md](docs/hardware.md) | hardware validation summary (ZCU106 + ConnectX-6 Dx at 10G and 40G) |
| [docs/projects.md](docs/projects.md) | projects using omac: per design, the IPs and targets, port mapping, register worked example, full-design resources, measured results |
| [docs/roadmap.md](docs/roadmap.md) | planned work |
| [CHANGELOG.md](CHANGELOG.md) | versions |

## Repository layout

```
ip/<ip>/rtl     the IP (SystemVerilog; <ip>.f = compile order; <ip>_bd.v = IPI wrapper)
ip/<ip>/sim     the IP's testbenches and test drivers
ip/<ip>/synth   out-of-context synthesis job lists and synthesis-only tops (make synth / synth40)
common/         shared blocks: CRC-32, 64B/66B codec + scrambler, block lock, BER monitor,
                RS link fault, PAUSE, clock crossing, AXI-Lite statistics
gt/             transceiver wrappers per family (gtwizard generator scripts + wrapper RTL)
docs/           the documentation (Sphinx / Read the Docs): interface contract, one page per IP, ...
sim/            the regression runner, the Python reference model, common-block tests
scripts/        helper scripts (IPI wrapper generator, out-of-context synthesis runner)
```

## Tools

Simulation: Vivado 2025.x xsim (`make sim`, about 16 minutes) and Python 3 (standard library
only). Synthesis: Vivado 2025.x (`make synth`, `make synth40`). Both scripts find Vivado on `PATH`, through
`VIVADO_SETTINGS`, or in the usual install locations. Documentation: Sphinx with myst-parser and
sphinx-rtd-theme (`make docs`, `pip install -r docs/requirements.txt`).

## Versions

One tag series for the whole repository (`vX.Y.Z`); the maturity of each IP is the table above
and its CHANGELOG entry. `dev` holds work in progress, `main` holds releases.

## Contribute

We strongly encourage community contribution to these projects. Please make a pull request if you
would like to share your work:
* if you've spotted and fixed any issues
* if you've added support for other transceiver families or devices
* if you've added a MAC (1G, 100G, RS-FEC) or validated one on new hardware

Thank you to everyone who supports us!

## About us

This project was developed by [Opsero Inc.](https://opsero.com "Opsero Inc."),
a tight-knit team of FPGA experts delivering FPGA products and design services to start-ups and tech companies.
Follow our blog, [FPGA Developer](https://www.fpgadeveloper.com "FPGA Developer"), for news, tutorials and
updates on the awesome projects we work on.

## License

MIT, see [LICENSE](LICENSE). Copyright (c) 2026 Opsero Electronic Design Inc.
