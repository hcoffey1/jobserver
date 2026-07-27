#!/bin/bash
# =============================================================================
# add_sweep_jobs_fallback.sh — queue the fallback-starvation A/B study onto the
# shared `regent` pool.
# =============================================================================
# Same dispatch mechanics as add_sweep_jobs_fig6.sh.  Differences:
#
#   * SWEEP points at sweep_fallback_policy.sh, which runs the
#     policy x ratio(0.1,0.25,2) x iter(5) grid for ONE workload on ONE node.
#   * Only THREE workloads — the ones where REGENT underperforms Memtis at
#     constrained fast-tier ratios: renaissance naive-bayes, graph500, and
#     npb-cpp IS.  One workload per node removes cross-node variability from the
#     violins (see CONTEXT.md "Fallback starvation" for the mechanism).
#   * Distinct RUN_TAG => separate sweep_runs_<tag>/ (workers) and
#     sweep_results_<tag>/ (here); nothing collides with fig6/spike10.
#
# TWO-WAVE PLAN.  This dispatches the "before" / no-fix arm (POLICIES defaults
# to the 4 fig6 policies).  It needs NO code change and its per-cell sweep.log
# ([Regent] Rebalance MAR/alloc/footprint) is what designs the fallback fix.
# When the fix lands as a runtime toggle, re-run this with FIX_POLICIES set to
# the fix arm's policy name — sweep_simple_freq_compare.sh --appends into the
# SAME per-workload MASTER_DIR and skips the already-completed cells, so only
# the new arm runs and the cached lib is reused.
#
# PREREQ: the wrapper must be present on every worker at
#   ~/working/regent/scripts/working_scripts/sweep_fallback_policy.sh
# Push it (distribute_regent.sh / rsync) before running this dispatcher, or
# every job fails immediately ("No such file").
# =============================================================================

CLASS=regent
SWEEP="$HOME/working/regent/scripts/working_scripts/sweep_fallback_policy.sh"
RUN_TAG="${RUN_TAG:-fallback_ab}"
RUNS="$HOME/working/sweep_runs_${RUN_TAG}"                 # per-workload MASTER_DIR root (worker)
CP="./sweep_results_${RUN_TAG}"                            # local aggregation dir (this machine)
J_BIN="${EXPJOBSERVER_CLIENT:-j}"

# Optional fix-arm handoff: set FIX_POLICIES="<policy name>" (and, once the fix
# is a runtime env toggle, it is exported through the job command below) to
# append the fix arm into the existing trees on a second wave.  Empty => the
# default 4-policy "before" arm defined in sweep_fallback_policy.sh.
FIX_POLICIES="${FIX_POLICIES:-}"

# The copier only creates the LEAF dir under $CP; ensure the root exists first.
mkdir -p "$CP"

add_fallback() {                                          # add_fallback <name>: one job per workload
    local w="$1"
    local extra=""
    [[ -n "$FIX_POLICIES" ]] && extra="POLICIES=$FIX_POLICIES "
    "$J_BIN" job add $CLASS "{MACHINE} env ${extra}MASTER_DIR=$RUNS/$w bash $SWEEP $w" "$CP"
}

# --- the three underperforming workloads (constrained-ratio losses vs Memtis)-
for w in renaissance_naive-bayes graph500 npb-cpp_is; do
    add_fallback "$w"
done

echo
echo "Queued fallback A/B jobs (class=$CLASS, tag=$RUN_TAG, policies=${FIX_POLICIES:-<default 4>})."
echo "Track with: j job ls"
echo "Results copy back to: $CP/"
