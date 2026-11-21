# omac_mdio

MDIO master (IEEE 802.3 clause 22 and clause 45) with AXI4-Lite registers. `rtl/` (the IP;
`omac_mdio.f` = compile order, `omac_mdio_bd.v` = IP integrator wrapper), `sim/` (testbench with
behavioural PHY models and its driver), `synth/` (out-of-context synthesis jobs), `drivers/linux/`
(MDIO-bus driver, device-tree binding), `drivers/baremetal/` (C driver and its host unit test).

Documentation: [docs/omac_mdio.md](../../docs/omac_mdio.md), also at
[omac.ethernetfmc.com](https://omac.ethernetfmc.com/en/latest/omac_mdio.html).
