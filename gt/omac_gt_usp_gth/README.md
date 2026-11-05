# omac_gt_usp_gth: UltraScale+ GTH wrappers

`gen_gt.tcl` (gtwizard generator: `omac_gen_gth`, `omac_gen_gth_x4`), `omac_gt_usp_gth.sv` (one
lane, for omac_10g) and `omac_gt_usp_gth_x4.sv` (four lanes, for omac_40g).

Documentation: [docs/gt_usp_gth.md](../../docs/gt_usp_gth.md), also at
[omac.ethernetfmc.com](https://omac.ethernetfmc.com/en/latest/gt_usp_gth.html) (including the
resets and handshake as software sees them: hold `reset_all` until the reference clock runs).
