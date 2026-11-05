# common: shared building blocks

The blocks every omac IP uses (CRC-32, 64B/66B codec and scrambler, block lock, BER monitor, RS
link fault, PAUSE, clock crossing) and the optional AXI-Lite statistics block (48-bit saturating
counters, clear-all only; it is not a driver interface, see the software contract in
[docs/interface.md](../docs/interface.md)).

Documentation: [docs/common.md](../docs/common.md), also at
[omac.ethernetfmc.com](https://omac.ethernetfmc.com/en/latest/common.html).
