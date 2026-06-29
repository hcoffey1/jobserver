#!/bin/bash
# =============================================================================
# add_smoke_jobs.sh — queue a one-shot characterization "smoke" job per workload.
# =============================================================================
# Adds ONE job per descriptor in workloads/config/workload_descriptors/ (42 of
# them).  Each job runs that workload ONCE under the fixed smoke configuration
# (50% peak-RSS fast tier, bucket clustering, simple_frequency policy, viz on)
# via the regent-side wrapper smoke_workload.sh, which emits a RESULTS line and
# exits non-zero if the workload failed -- so `j job ls` shows pass/fail directly.
#
# Why: exercise job dispatch across the machine pool, see which benchmarks
# succeed vs fail, and copy each run's stdout + plots back here so we can later
# mine per-workload "swept metric" regexes to add to sweep_cluster.sh's
# PLOT_METRICS (the violin-plot feature extraction).
#
# Results aggregate under ./smoke_results/<suite>_<workload>/.  After the run:
#   j job ls                                         # dispatch + pass/fail view
#   grep -H 'fail:' ./smoke_results/*/run_summary.log   # which workloads failed
#   less ./smoke_results/<slug>/<wdir>/*              # raw stdout to harvest from
# =============================================================================
set -euo pipefail

CLASS=regent                                                   # matches registered machines
WRAPPER='~/working/regent/scripts/working_scripts/smoke_workload.sh'   # ~ expands on the remote
DESC_DIR="$HOME/working/workloads/config/workload_descriptors"
CP_ROOT=./smoke_results                                        # local aggregation root
J_BIN="${EXPJOBSERVER_CLIENT:-j}"                              # 'j' isn't on PATH by default

[[ -d "$DESC_DIR" ]] || { echo "ERROR: no descriptor dir at $DESC_DIR" >&2; exit 1; }

# The copier rsyncs each job's results into "$CP_ROOT/<slug>" but only creates
# that LEAF dir -- rsync does not mkdir intermediate parents.  If $CP_ROOT itself
# is missing, EVERY copy-back fails with "mkdir ... No such file or directory",
# the server counts each as a machine failure, and after MACHINE_FAILURES (4) it
# demotes the machine to class "<class>-broken" -- bricking the whole pool.  So
# guarantee the aggregation root exists before queuing anything.
mkdir -p "$CP_ROOT"

count=0
for f in "$DESC_DIR"/*.conf; do
    # Read identity from the descriptor (single source of truth), not the
    # filename -- gapbs_sssp_twitter etc. don't split cleanly on '_'.  Source in
    # a subshell so the .conf's assignments never leak into this loop.
    read -r suite workload < <(suite=""; workload=""; . "$f"; printf '%s %s\n' "$suite" "$workload")
    if [[ -z "$suite" || -z "$workload" ]]; then
        echo "WARN: skipping $(basename "$f") (missing suite/workload)" >&2
        continue
    fi
    slug="${suite}_${workload}"
    "$J_BIN" job add "$CLASS" "{MACHINE} bash $WRAPPER ${suite}:${workload}" "$CP_ROOT/$slug"
    count=$((count + 1))
done

echo
echo "Queued $count smoke jobs (class $CLASS).  Track with:  j job ls"
echo "When done, scan failures with:  grep -H 'fail:' $CP_ROOT/*/run_summary.log"
