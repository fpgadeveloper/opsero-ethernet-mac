# opsero-ethernet-mac

**opsero-ethernet-mac** (omac) is a collection of open-source Ethernet MAC + PCS cores for
FPGAs, written from scratch in vendor-neutral SystemVerilog from IEEE 802.3 (clauses 46, 49, 81,
82 and annex 31B) and released under the MIT license. No licensed MAC, PCS or evaluation IP is
involved: the transceiver is reached through a small per-family wrapper around the vendor's free
transceiver wizard.

Every core presents the same user-side boundary, the [interface contract](interface.md):
AXI-Stream transmit and receive on one user clock, FCS handled inside, PAUSE as levels, and a
common status, control and event bundle. A design can therefore swap one MAC for another (or for
a hard MAC behind a thin wrapper) without touching the logic around it.

Source code, releases and issues:
[github.com/fpgadeveloper/opsero-ethernet-mac](https://github.com/fpgadeveloper/opsero-ethernet-mac).
The collection was created for Opsero's reference designs; the designs that use it, with their
measured results, are on the [projects page](projects.md). `omac_40g` and `omac_10g` are
validated on a ZCU106 against an NVIDIA ConnectX-6 Dx ([](hardware.md)). The cores are not
tied to a board: any device with a supported transceiver wrapper (today
UltraScale+ GTH) can use them; the board-specific part (which GT channels, which reference
clock) is the design's ([](gt_usp_gth.md#board-placement)).

## IP cores

| IP | Standard | User side | Lanes | Maturity |
|---|---|---|---|---|
| [`omac_10g`](omac_10g.md) | 10GBASE-R; 25GBASE-R with `SPEED` = 25 | 64-bit AXI-Stream at 156.25 MHz (25G: 390.625 MHz) | 1 x 10.3125 Gb/s (25G: 1 x 25.78125) | **10GBASE-R: hardware-proven** on a ZCU106 against a ConnectX-6 Dx ([](hardware.md)). 25GBASE-R: simulated, timing closed at 390.625 MHz on xcku5p-2, not yet on hardware (needs a GTY wrapper) |
| [`omac_40g`](omac_40g.md) | 40GBASE-R4 (multi-lane distribution, alignment markers, BIP, deskew, lane reorder) | 256-bit AXI-Stream at 156.25 MHz | 4 x 10.3125 Gb/s | **hardware-proven** on a ZCU106 against a ConnectX-6 Dx at 40GBASE-CR4 ([](hardware.md)) |
| `omac_1g` | 1000BASE-X / SGMII | 8-bit | 1 x 1.25 Gb/s | planned ([](roadmap.md)) |
| `omac_100g` | 100GBASE-R4 with RS-FEC | 512-bit | 4 x 25.78125 Gb/s | planned ([](roadmap.md)) |

| Transceiver wrapper | Family | Maturity |
|---|---|---|
| [`omac_gt_usp_gth`, `omac_gt_usp_gth_x4`](gt_usp_gth.md) | UltraScale+ GTH, 64B/66B asynchronous gearbox (AMD `gtwizard_ultrascale`, free); one lane (omac_10g) or four lanes of one quad with per-lane receive clocks (omac_40g) | **hardware-proven** with both IPs (ZCU106, [](hardware.md)) |
| `omac_gt_usp_gty` | UltraScale+ GTY | planned |

Every IP comes with a self-checking simulation regression against an independent Python model
of the standard ([](simulation.md)) and out-of-context implementation results
([](resources.md)). One tag series covers the whole repository (`vX.Y.Z`); the maturity of each
IP is the table above and its entry in the
[CHANGELOG](https://github.com/fpgadeveloper/opsero-ethernet-mac/blob/main/CHANGELOG.md).

## License

MIT, see [LICENSE](https://github.com/fpgadeveloper/opsero-ethernet-mac/blob/main/LICENSE).
Copyright (c) 2026 Opsero Electronic Design Inc. The transceiver wizard IP that the `gt/`
generator scripts create (`gtwizard_ultrascale`) is AMD's and needs no license key.

## Using the cores

### As a git submodule

The repository is meant to be pulled into a design as a git submodule. Each IP lists its
sources in compile order in `ip/<ip>/rtl/<ip>.f` (paths relative to the repository root),
including the `common/` blocks it needs:

```
git submodule add https://github.com/fpgadeveloper/opsero-ethernet-mac submodules/opsero-ethernet-mac
```

```tcl
# Vivado: read the IP's source list
set omac submodules/opsero-ethernet-mac
foreach f [split [read [open $omac/ip/omac_40g/rtl/omac_40g.f]] "\n"] {
    if {$f ne "" && [string index $f 0] ne "#"} { read_verilog -sv $omac/$f }   ;# or add_files
}
# the transceiver: generate the free gtwizard IP and add the wrapper
source $omac/gt/omac_gt_usp_gth/gen_gt.tcl
# the board's GT channel sites, QSFP lane 0 first (omac_10g: omac_gen_gth ./ip <channel-site>)
omac_gen_gth_x4 ./ip {<lane0> <lane1> <lane2> <lane3>}
read_verilog -sv $omac/gt/omac_gt_usp_gth/omac_gt_usp_gth_x4.sv
```

When the design synthesises in memory with `synth_design` (no out-of-context IP runs), set the
generated transceiver IP to global synthesis; see [](gt_usp_gth.md#global-synthesis).

### In RTL

Instantiate the IP and its transceiver wrapper and connect the GT side; each IP page shows the
connection, and `ip/<ip>/synth/<ip>_gth_top.sv` is a complete example (the synthesis check of
the pair). All user logic runs on the wrapper's `tx_usrclk2` (the IP's `clk`).

### In an IP integrator block design (module reference)

Add `ip/<ip>/rtl/<ip>_bd.v` as a module reference: a generated Verilog wrapper around the
SystemVerilog top (module references need a Verilog top file), whose AXI-Streams, clock and
reset IPI recognises as interfaces. Alternatively, put the IP and its transceiver wrapper in
one small Verilog module and add that as the module reference. Several such modules (one per
MAC, or a hard-MAC adapter) with the same ports let one block design take any of them.

### Bring-up checklist

1. Make the 156.25 MHz reference clock stable first (for example, a programmable clock
   generator on the FMC must be programmed first), then release the wrapper's `reset_all`.
2. Constrain the reference clock (`create_clock -period 6.400`) and the clock crossings in an
   implementation-only XDC ([](gt_usp_gth.md#clock-constraints)).
3. Force the link partner to the line rate with auto-negotiation off and FEC off (omac has no
   clause 73 auto-negotiation and no FEC), for example on a ConnectX NIC:
   `ethtool -s <if> speed 40000 duplex full autoneg off` and `ethtool --set-fec <if> encoding off`.
4. Watch `stat_link_up` (allow up to 10 s: the partner's own link-up dominates); if it does not
   come, follow the debug order of the IP page: [](omac_10g.md#bring-up-and-software),
   [](omac_40g.md#bring-up-and-software).

### No drivers, by design

The cores ship without a driver: no register block inside the IPs, no Linux netdev, no
bare-metal library. A design folds the MAC's static control and status ports into its own
register block (each design puts something different behind the MAC), and its software brings
the link up through those registers. What the registers must expose, the clock-domain rule, the
counters, the interrupts and a worked example are the
[software contract](interface.md#6-software-contract); the sequence, timing and debug order of
each IP are on its page.

## Contents

```{toctree}
:maxdepth: 2
:caption: Cores

interface
omac_10g
omac_40g
gt_usp_gth
common
```

```{toctree}
:maxdepth: 2
:caption: Verification and status

simulation
resources
hardware
projects
roadmap
```

## Elsewhere in the repository

* [README](https://github.com/fpgadeveloper/opsero-ethernet-mac#readme): overview, repository
  layout, how to run the regression and the synthesis jobs.
* [CHANGELOG](https://github.com/fpgadeveloper/opsero-ethernet-mac/blob/main/CHANGELOG.md):
  versions, what changed, the known limitations of each version.
