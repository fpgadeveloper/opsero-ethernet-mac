# omac_40g

`rtl/` (the IP; `omac_40g.f` = compile order, `omac_40g_bd.v` = IP integrator wrapper), `sim/`
(testbenches and test drivers), `synth/` (out-of-context synthesis jobs).

Documentation: [docs/omac_40g.md](../../docs/omac_40g.md), also at
[omac.ethernetfmc.com](https://omac.ethernetfmc.com/en/latest/omac_40g.html). There is no driver
by design: bring-up, link-up time and the per-lane debug order are in its "Bring-up and
software" section, the registers a design must expose in the software contract of
[docs/interface.md](../../docs/interface.md).
