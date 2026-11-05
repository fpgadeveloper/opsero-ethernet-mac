# Common building blocks

Used by the omac IPs (each IP's `rtl/<ip>.f` lists the ones it needs, package first).

| Module | Function |
|---|---|
| `omac_pkg` | XGMII control characters, 64B/66B sync headers, block types and control codes, `enc66` / `dec66` (one 64-bit column ↔ one 66-bit block, IEEE 802.3 figure 49-7), `scramble` / `descramble` (x^58 + x^39 + 1, 64 bits per call), `crc32_byte`, CRC init and residue |
| `omac_crc32` | combinational CRC-32 update over the first `nbytes` of a `BYTES`-wide word (any width; cost grows with `BYTES`^2) |
| `omac_scrambler`, `omac_descrambler` | registered 64-bit scrambler / self-synchronising descrambler |
| `omac_block_lock` | 64B/66B block lock state machine (figure 49-14) with gearbox slip and a slip wait |
| `omac_ber_mon` | BER monitor (figure 49-15): `THRESH` bad headers per `TIMER_CLKS` window |
| `omac_rs_fault` | RS link fault detection (figure 46-11) on any number of 4-byte columns per cycle |
| `omac_pause` | 802.3x PAUSE: receive timer in bit times (speed-independent through `BIT_TIMES_PER_CLK`), XOFF / refresh / XON requests from a level |
| `omac_pause_frame` | AXI-Stream source of one PAUSE frame (60 bytes, any width) |
| `omac_async_fifo` | dual-clock FIFO, gray pointers, LUTRAM, first-word fall-through |
| `omac_sync_bit`, `omac_sync_reset` | level synchroniser (`ASYNC_REG`), reset synchroniser |
| `omac_cdc_event` | loss-free crossing of event pulses (gray-coded counter per event) |
| `omac_axil_stats` | optional AXI4-Lite statistics block (below) |

## omac_axil_stats register map

One clock (the IP's `clk`); 32-bit registers, byte addresses; every access answers OKAY.

| Address | Name | Access | Description |
|---|---|---|---|
| 0x000 | `ID` | R | 0x4F4D4143 ("OMAC") |
| 0x004 | `VERSION` | R | `VERSION` parameter |
| 0x008 | `NCNT` | R | number of counters |
| 0x00C | `STATUS` | R | the `stat` input (connect the `stat_*` levels) |
| 0x010 | `CTRL` | W | bit 0: clear every counter |
| 0x100 + 8 i | `CNT_LO[i]` | R | counter i bits 31:0; the read latches bits 47:32 |
| 0x104 + 8 i | `CNT_HI[i]` | R | counter i bits 47:32 as latched by the last `CNT_LO` read |

Counters are 48 bits and saturate at 2^48-1; there is no clear-on-read, `CTRL` bit 0 clears all
of them at once. Read `CNT_LO[i]` before `CNT_HI[i]` (one high-half latch for the whole block).
Suggested order for omac_10g (`NCNT` 12): the `ev_*` ports in the order of docs/interface.md 1.7.
The block runs on the IP's `clk`, which stops while the transceiver is in reset: reach it only
through a guard that answers while `clk` is stopped ([](interface.md#61-clock-domains-keep-the-registers-reachable)).
How software uses the counters: [](interface.md#63-counters).
