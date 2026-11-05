# SPDX-License-Identifier: MIT
# opsero-ethernet-mac - convenience targets
#   make sim          full simulation regression (Vivado xsim + Python models)
#   make sim-quick    the same with smaller workloads
#   make synth        out-of-context synthesis of omac_10g (xczu7ev @ 156.25 MHz, xcku5p @ 390.625 MHz)
#   make synth-gt     generate a one-channel GTH gtwizard IP (xczu7ev) and synthesize it with omac_10g
#   make synth40      out-of-context synthesis + route of omac_40g (xczu7ev @ 156.25 MHz)
#   make synth40-gt   a four-lane GTH gtwizard IP (one xczu7ev quad) synthesized with omac_40g
#   make docs         build the documentation (sphinx, myst-parser, sphinx-rtd-theme)
#   make clean
PYTHON ?= python3

.PHONY: sim sim-quick synth synth-gt synth40 synth40-gt docs clean

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

docs:
	sphinx-build -W -b html docs docs/_build/html

clean:
	rm -rf sim/build ip/*/synth/build gt/*/build docs/_build
