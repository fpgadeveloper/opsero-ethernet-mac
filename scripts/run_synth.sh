#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# run_synth.sh <jobs.txt> [out_dir] - run synth_ooc.tcl on a job list (ip/<ip>/synth/jobs*.txt:
# the IP is taken from the path) in ONE Vivado batch process. Waits while MAX_JOBS (default 2) or more Vivado processes run on the host, so a
# shared build machine is not overloaded. Needs vivado on PATH or VIVADO_SETTINGS (a few
# usual install locations are tried).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(readlink -f "$1")"
OUT="$(readlink -m "${2:-$(dirname "$JOBS")/build}")"
MAX_JOBS="${MAX_JOBS:-2}"
mkdir -p "$OUT"
if ! command -v vivado >/dev/null 2>&1; then
    if [ -z "${VIVADO_SETTINGS:-}" ]; then
        for c in /tools/Xilinx/*/Vivado/settings64.sh "$HOME"/Xilinx/*/Vivado/settings64.sh /opt/Xilinx/*/Vivado/settings64.sh; do
            [ -f "$c" ] && VIVADO_SETTINGS="$c"
        done
    fi
    [ -n "${VIVADO_SETTINGS:-}" ] || { echo "put vivado on PATH or set VIVADO_SETTINGS" >&2; exit 1; }
    set +u
    # shellcheck disable=SC1090
    source "$VIVADO_SETTINGS"
    set -u
fi
# count Vivado batch jobs, not the parallel synthesis workers (task_worker.tcl) of one job
nviv() { pgrep -a -x vivado | grep '/unwrapped/' | grep -vc 'task_worker' || true; }
while [ "$(nviv)" -ge "$MAX_JOBS" ]; do
    echo "$(date +%T) waiting: $(nviv) Vivado jobs running"
    sleep 60
done
LOG="$OUT/$(basename "$JOBS" .txt)_$(date +%Y%m%d_%H%M%S).log"
echo "log: $LOG"
cd "$OUT" && vivado -mode batch -nojournal -nolog -notrace -source "$HERE/synth_ooc.tcl" \
    -tclargs "$JOBS" "$OUT" > "$LOG" 2>&1
grep -E "^(JOB_|=== JOB)" "$LOG"
