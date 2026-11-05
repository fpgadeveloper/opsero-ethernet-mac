# Projects using omac

The designs below use the omac cores. Each section says what the project is, which omac IPs it
uses on which target, how it connects them, and what was measured on hardware in it. The generic
pages ([interface contract](interface.md), the IP pages, [](gt_usp_gth.md)) describe the cores
on their own; this page holds everything that is specific to one design. It grows as more
designs adopt the cores.

## qsfp28-fmc-rocelet

An open-source RoCE v2 (RDMA over Converged Ethernet) reference design for the Opsero
2x QSFP28 FMC (OP120). Its engine, [rocelet](https://rocelet.ethernetfmc.com/en/latest/), moves
data between FPGA memory and a host's memory or GPU over RDMA. On devices without a hard 100G
MAC, omac gives it a license-free 40 GbE link to an NVIDIA ConnectX-6 Dx (`omac_40g`) and a
10 GbE option (`omac_10g`). The omac cores were written for this design and validated in it.

| | |
|---|---|
| Design documentation | [qsfp28-rocelet.ethernetfmc.com](https://qsfp28-rocelet.ethernetfmc.com/en/latest/) |
| Engine documentation | [rocelet.ethernetfmc.com](https://rocelet.ethernetfmc.com/en/latest/) |
| Design source | [github.com/fpgadeveloper/qsfp28-fmc-rocelet](https://github.com/fpgadeveloper/qsfp28-fmc-rocelet) |
| Engine source | [github.com/fpgadeveloper/rocelet](https://github.com/fpgadeveloper/rocelet) |

### omac IPs per target

| Target | Board | MAC | omac IPs (design module) |
|---|---|---|---|
| `zcu106` | AMD ZCU106 (XCZU7EV-2, GTH), OP120 QSFP28 port 0 | 40GBASE-R4 (shipping) | `omac_40g` + `omac_gt_usp_gth_x4` (`mac_omac40g`) |
| `zcu106`, 10G option | the same, QSFP lane 0 | 10GBASE-R | `omac_10g` + `omac_gt_usp_gth` (`mac_omac10g`), selected in the design's manifest |
| `kcu116` | AMD KCU116 (GTY + hard CMAC) | 100GBASE-R4 | none: the hard CMAC behind an adapter (`mac_cmac_adapt`) that presents the same boundary ([](interface.md#5-implementations-of-the-boundary)) |

The design puts each MAC and its transceiver wrapper in one small Verilog module
(`Vivado/src/hdl/mac/mac_omac40g.v`, `mac_omac10g.v`, `mac_cmac_adapt.v`) and adds that module
to the block design as a module reference. All three present one fixed MAC boundary, so the same
block design takes `omac_40g`, `omac_10g` or the CMAC adapter. The design's build sets the
generated transceiver IP to global synthesis ([](gt_usp_gth.md#global-synthesis)).

The board-specific part (GT channel sites in QSFP lane order, the reference clock pin and its
clock generator, the lane map, the constraints) is the "Board specifics" section of the
design's [Zynq UltraScale+ hardware reference](https://qsfp28-rocelet.ethernetfmc.com/en/latest/zynqmp_hw.html#board-specifics).
Its transceiver settings are build-time parameters: `BIT_REVERSE` = 1, `CH_OF_LANE` from the
board's lane order, polarity 0, `tx_diffctrl` 5'b11000, DFE (`rx_lpmen` = 0).

### Port mapping: omac to rocelet (v0.3 and later)

The authoritative mapping is rocelet's interface page
([rocelet.ethernetfmc.com, "MAC side"](https://rocelet.ethernetfmc.com/en/latest/interface.html#mac-side));
the generic version of this table is [](interface.md#4-connecting-a-consumer).

| rocelet port | omac port |
|---|---|
| `clk` | `clk` (rocelet `MAC_WIDTH` = the IP's `DATA_WIDTH`: 64 for `omac_10g`, 256 for `omac_40g`; `CLK_KHZ` 156250; `LINK_GBPS` 10 / 40) |
| `s_axis_rx_*` / `m_axis_tx_*` | `m_axis_rx_*` / `s_axis_tx_*` (`m_axis_tx_tuser` → `s_axis_tx_tuser`, always 0) |
| `link_up` | `stat_link_up` |
| `mac_rx_status` | `stat_block_lock` |
| `mac_pause_hold` | `stat_rx_pause_req` (with `CTRL.PAUSE_RX_LEVEL` = 1; `ctl_pause_tx_honour` = 0) |
| `mac_pause_valid`, `mac_pause_quanta` | tie 0 (omac times the quanta itself) |
| `mac_pause_req` | `ctl_tx_pause_send` (XOFF quanta / refresh in `ctl_tx_pause_quanta` / `ctl_tx_pause_refresh`) |
| `mac_pause_rx_frame` / `mac_pause_tx_frame` | `ev_rx_pause` / `ev_tx_pause` |
| `mac_rx_reset`, `mac_tx_reset`, `mac_fec_corr_inc`, `mac_fec_uncorr_inc` | tie 0 |

rocelet's transmit path is store-and-forward (it never leaves a gap inside a frame) and its
receive FIFO writes every valid beat (no `tready`, gaps allowed), as the contract requires.
Its PAUSE request rises when its receive FIFO is above 128 beats and falls below 64.

### Register wrapper (worked example of the software contract)

The ZCU106 target spreads the MAC ports over two register blocks: an **always-on block** in the
processor's register clock (`Vivado/src/hdl/rsys_aon.sv`, which also guards every access into the
MAC clock) and the system registers of the engine in the MAC clock. The design's
[hardware reference](https://qsfp28-rocelet.ethernetfmc.com/en/latest/zynqmp_hw.html) documents
the registers (sections "Always-on registers", "Bring-up sequence (software)", "MAC boundary",
"PAUSE"); the bring-up code is `Vitis/common/src/mac.c`, used by the bare-metal console and,
unchanged, by the Linux daemon `sw/linux/roceletd`. It implements the
[software contract](interface.md#6-software-contract) as follows:

| omac / wrapper port | rocelet register | Clock |
|---|---|---|
| wrapper `reset_all` | always-on `CTRL[0]` `GT_RST`, reset 1 | always on |
| omac `rst` | always-on `CTRL[1]` `MAC_RST`, reset 1 (ORed with `!gt_tx_ready` in `mac_omac*`) | always on |
| `ctl_rx_enable`, `ctl_tx_enable`, `ctl_tx_fault` | `C_MAC_CTL[0]`, `[1]`, `[3]` | MAC, guarded |
| `ctl_loopback` | `C_MAC_CTL[10:8]` ≠ 0 | MAC, guarded |
| `ctl_tx_pause_send` | `C_MAC_CTL[7]` (PAUSE TX enable) AND the engine's request (receive FIFO above 128 beats, released below 64) | MAC, guarded |
| `ctl_tx_pause_quanta`, `ctl_tx_pause_refresh` | `C_MAC_PZ[15:0]`, `[31:16]` (0x100, 0x80) | MAC, guarded |
| `ctl_mac_addr` | `C_MAC_ADDR_LO`, `C_MAC_ADDR_HI` | MAC, guarded |
| `ctl_pause_tx_honour` | tied 0: the engine honours `stat_rx_pause_req` itself when its PAUSE RX is enabled | |
| `gt_powergood`, `gt_tx_ready`, `gt_rx_ready`, `stat_block_lock`, `stat_link_up`, `stat_hi_ber`, `stat_local_fault`, `stat_remote_fault` | always-on `STATUS[1]`-`[8]` (synchronised); `STATUS[0]` = MAC clock alive, `MAC_KHZ` = measured `clk` | always on |
| edges of `stat_link_up` | always-on `LINK_EV` (up / down counts), `IRQ_STATUS[0]` (both edges) | always on |
| `stat_lane_*` | always-on `LANE_STAT` | always on |
| `ev_rx_bip_error[3:0]`, `ev_rx_skew_fail`, `ev_rx_overflow` | always-on `LANE_BIP0`-`3`, `SKEW_FAIL`, `RX_OVF` (32-bit wrapping, cleared by a write to `LANE_STAT`) | always on |
| the other `ev_*` | the engine's MAC counters (RX frames, bad FCS, bad code = `ev_rx_bad_block`, TX frames, underflow, PAUSE received / sent) | MAC, guarded |

The engine counts the `ev_*` pulses in free-running 16-bit counters in `clk`, crosses them
gray-coded into the always-on clock and accumulates them into 32-bit wrapping counters that a
write clears; software takes differences modulo 2^32.

### Bring-up firmware

`mac.c` follows the bring-up sequence of the IP pages
([](omac_10g.md#bring-up-and-software), [](omac_40g.md#bring-up-and-software)) with these
choices:

| Step | What the firmware does |
|---|---|
| reference clock | programs the FMC's clock generator over I2C, then waits 20 ms |
| transceiver | releases `GT_RST`, polls `gt_tx_ready` every 1 ms with a 1 s limit, then reads `MAC_KHZ` (the meter integrates over 1 ms, so it waits 2.5 ms before it expects 156250) |
| MAC reset | pulses `MAC_RST` for 1 ms before it writes the configuration, and again once a second while it waits for the link (inherited from the CMAC flow; omac does not need it, its RX watchdog restarts the RX datapath by itself; the measured link-up times include it) |
| link | polls `stat_link_up` every 100 ms, reports "no link" after 10 s |
| relink | the console's `link` command is a `MAC_RST` pulse |
| loopback | writes `ctl_loopback`, pulses `MAC_RST` and waits for the link as at bring-up; the design's 19-test RoCE self-test runs in near-end PMA loopback with the cable to the partner still connected |

### Status dumps

The bare-metal console's `st` command (on Linux: `rl st`) prints the MAC status and counters.
A healthy 10G link after traffic reads: link up, block lock 1, hi BER 0, local and remote fault
0; RX frames counting, bad FCS 0, errored blocks 0 since link-up, TX frames counting, TX
underflow 0, link drops 0.

At 40G it adds the per-lane state as one line, here on a healthy link right after link-up
(ZCU106 against a ConnectX-6 Dx):

```text
lanes 0-3: block lock 1111 | AM lock 1111 | PCS lane on QSFP lane 0-3: 0 1 2 3 | skew 1 blocks | BIP errors 0 0 0 0 | skew fails 1 | RX overflow 0
```

The `lanes:` line is what the debug order of [](omac_40g.md#when-it-does-not-link-debug-order)
reads: `stat_lane_block_lock`, `stat_lane_am_lock`, `stat_lane_map`, `stat_lane_skew` and the
per-lane counters.

### Clock constraints

The design uses exactly the implementation-only constraints of
[](gt_usp_gth.md#clock-constraints) for both omac MACs (its XDC is in the "Board specifics"
section linked above), checked with `report_clock_interaction` (every pair "Max Delay Datapath
Only") and closed with positive slack in the routed design.

### Resources in the full design

In the ZCU106 design (XCZU7EV-2, Vivado 2025.2, routed with the rest of the design: the rocelet
RoCE v2 engine, the Zynq UltraScale+ PS, PS DDR and DMA paths), the MAC hierarchy `omac_40g` +
`omac_gt_usp_gth_x4` uses **16,762 LUT and 8,752 FF**, and the whole design closes timing at
156.25 MHz (WNS +0.134 ns, WHS +0.010 ns, 0 critical warnings). The design's resource page lists
the full build with both MAC options:
[qsfp28-rocelet.ethernetfmc.com](https://qsfp28-rocelet.ethernetfmc.com/en/latest/resources.html).
The out-of-context figures of the cores alone are on [](resources.md).

### Measured on hardware

Release 0.5.0 of the design (rocelet v0.3.0, omac v0.1.0); summary on [](hardware.md).

| Item | Setup |
|---|---|
| FPGA board | AMD ZCU106 (XCZU7EV-2, GTH transceivers) |
| FMC | Opsero 2x QSFP28 FMC (OP120), QSFP28 port 0 (four GTH channels of one quad, 156.25 MHz reference clock from the FMC's clock generator) |
| Cable | 3 m passive QSFP28 direct-attach copper cable |
| Link partner | NVIDIA ConnectX-6 Dx (firmware 22.43.2566, inbox mlx5 driver and rdma-core, Ubuntu 24.04), forced to the line rate: `speed 40000` (or `10000`), auto-negotiation off, FEC off, MTU 4200 |
| omac | v0.1.0, wrapper settings as above |

#### omac_40g (40GBASE-CR4)

| What | Measured |
|---|---|
| Link | block lock and marker lock on all four lanes and alignment on the first power-up; link up 4.8-5.7 s after the MAC reset release (including the firmware's polling and the partner's own link-up). Lane map from the partner: identity (PCS lane l on QSFP lane l); skew 0-1 block; the partner reports Active 40G, 4 lanes, no FEC |
| RoCE v2 throughput (payload, PMTU 4096) | FPGA to host WRITE with immediate 38.83 Gb/s; host WRITE into FPGA memory 38.74 Gb/s; host SEND 39.20 Gb/s; host READ of FPGA memory 38.73 Gb/s, and at line rate for PMTU 1024 (37.0 Gb/s) and 512 (34.4 Gb/s) |
| Streaming | 1 MiB Holoscan Sensor Bridge frames into GPU memory at 39.0 Gb/s, every frame checked, 0 lost |
| Errors | after 85.9 million frames sent: 0 FCS errors, 0 errored blocks, 0 BIP errors on any lane, 0 receive overflows, 0 transmit underflows, 0 link drops; partner: 0 CRC and 0 symbol errors, no raw physical errors on any lane |
| PAUSE transmit | the `ctl_tx_pause_send` level (XOFF quanta 0x100 = 3.3 µs, refresh 0x80 = 1.6 µs) driven from the engine's receive FIFO level: 174,494 PAUSE frames sent, every one honoured by the partner (host WRITE throttled to a slower memory without a single lost packet) |
| PAUSE receive | 802.3x frames from the partner (quanta 0xFFFF, about every 2.1 ms): `stat_rx_pause_req` held the FPGA's transmit for 0.84 ms each (40 % of the time); WRITE with immediate dropped from 38.78 to 23.89 Gb/s with 0 lost (3,679 PAUSE frames honoured) |
| Near-end PMA loopback | `ctl_loopback` (GTH `LOOPBACK` 3'b010): the 19-test RoCE self-test passes in loopback, with the cable to the partner still connected |

#### omac_10g (10GBASE-R)

| What | Measured |
|---|---|
| Link | block lock and link on the first power-up, 3.3-5.6 s after the MAC reset release; the partner forced to `10000baseCR` uses QSFP lane 0 |
| RoCE v2 throughput (payload) | FPGA to host WRITE with immediate 9.80 Gb/s; host WRITE 9.69-9.71 Gb/s; host SEND 9.80 Gb/s; host READ 9.44-9.57 Gb/s |
| Errors | 1.3-1.75 million frames each way per run: 0 FCS errors, 0 errored blocks after link-up, 0 transmit underflows |
| Near-end PMA loopback | the 19-test self-test passes |

PAUSE frames have not been exchanged on a 10G link (the PAUSE block is the same `omac_pause`
proven at 40G).
