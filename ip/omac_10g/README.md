# omac_10g

`rtl/` (the IP; `omac_10g.f` = compile order, `omac_10g_bd.v` = IP integrator wrapper), `sim/`
(testbenches and test drivers), `synth/` (out-of-context synthesis jobs).

Documentation: [docs/omac_10g.md](../../docs/omac_10g.md), also at
[omac.ethernetfmc.com](https://omac.ethernetfmc.com/en/latest/omac_10g.html). There is no driver
by design: bring-up, link-up time and debug order are in its "Bring-up and software" section,
the registers a design must expose in the software contract of
[docs/interface.md](../../docs/interface.md).
