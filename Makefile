# SPDX-License-Identifier: MIT
# opsero-ethernet-mac - convenience targets
#   make sim          full simulation regression (Vivado xsim + Python models)
#   make sim-quick    the same with smaller workloads
#   make synth        out-of-context synthesis of omac_10g (xczu7ev @ 156.25 MHz, xcku5p @ 390.625 MHz)
#   make synth-gt     generate a one-channel GTH gtwizard IP (xczu7ev) and synthesize it with omac_10g
#   make synth40      out-of-context synthesis + route of omac_40g (xczu7ev @ 156.25 MHz)
#   make synth40-gt   a four-lane GTH gtwizard IP (one xczu7ev quad) synthesized with omac_40g
#   make synth-mdio   out-of-context synthesis + route of omac_mdio (xczu7ev, xcvc1902 @ 100 / 250 MHz)
#   make drv-mdio     host unit test of the omac_mdio bare-metal driver (cc)
#   make docs         build the documentation (sphinx, myst-parser, sphinx-rtd-theme)
#   make clean
#   make synth-gtq    omac_10g on the per-lane quad wrappers: GTY (xcku5p) and GTH (xczu7ev) jobs
#   make sim-gt       transceiver-level loop simulation of the quad wrappers (GT models, slow)
#   make synth-gtq-versal  omac_10g on the Versal GTY quad wrapper (xcvc1902, routed out of context)
PYTHON ?= python3

.PHONY: sim sim-quick synth synth-gt synth40 synth40-gt synth-mdio drv-mdio docs clean

sim:
	$(PYTHON) -I sim/run_tests.py

sim-quick:
	$(PYTHON) -I sim/run_tests.py --quick

synth:
	scripts/run_synth.sh ip/omac_10g/synth/jobs.txt ip/omac_10g/synth/build

synth-gt:
	scripts/run_synth.sh ip/omac_10g/synth/jobs_gt.txt ip/omac_10g/synth/build

synth40:
	scripts/run_synth.sh ip/omac_40g/synth/jobs.txt ip/omac_40g/synth/build

synth40-gt:
	scripts/run_synth.sh ip/omac_40g/synth/jobs_gt.txt ip/omac_40g/synth/build

synth-mdio:
	scripts/run_synth.sh ip/omac_mdio/synth/jobs.txt ip/omac_mdio/synth/build

drv-mdio:
	$(PYTHON) -I ip/omac_mdio/drivers/baremetal/test/test_omac_mdio_drv.py

docs:
	sphinx-build -W -b html docs docs/_build/html

clean:
	rm -rf sim/build ip/*/synth/build gt/*/build docs/_build

# per-lane quad wrappers (GTH / GTY)
.PHONY: synth-gtq synth-gtq-versal sim-gt
synth-gtq:
	scripts/run_synth.sh ip/omac_10g/synth/jobs_gtq.txt ip/omac_10g/synth/build

synth-gtq-versal:
	scripts/run_synth.sh ip/omac_10g/synth/jobs_gtq_versal.txt ip/omac_10g/synth/build

sim-gt:
	$(PYTHON) -I sim/run_tests.py --gt
