#!/bin/bash
# =============================================================================
# add_sweep_jobs_nursery.sh — queue the fallback-nursery A/B/C campaign
# (regent ADR-0015) onto the shared `regent` pool.
# =============================================================================
# Same dispatch mechanics as add_sweep_jobs_fallback.sh.  Differences:
#
#   * SWEEP points at sweep_nursery_policy.sh, which runs an ARM x ratio x iter
#     grid for ONE workload on ONE node: 3 arms x 3 ratios x 3 iters = 27 cells.
#   * The arms are SOURCE TREES, not runtime policies:
#         nursery_base         A  ~/working/regent_base  (hjcoffey/regent)
#         nursery_fix          B  ~/working/regent       (fallback_nursery), grace unset
#         nursery_fix_grace30  C  ~/working/regent       (fallback_nursery), grace=30 ticks
#     A->B isolates the ranking/water-fill change (unconditional on the branch);
#     B->C isolates the REGENT_DEMAND_GRACE_EPOCHS filter (the only env-gated
#     half).  With only A vs C the two are confounded.
#   * Ratios 0.2 / 0.5 / 1.1 -- high / mid / low fast-tier pressure.  1.1 is a
#     NULL CONTROL: budget exceeds footprint, leftover exists, so even the
#     pre-ADR-0015 arm funds the fallback and all three arms should converge.
#   * ITERS=3 -- median + min/max range only.  NOT enough for distribution
#     claims or violins; this is an exploratory go/no-go.
#   * FIVE workloads: three where the starvation symptom was measured, plus two
#     negative controls (gapbs_bc, spec_mcf) that did not show it.  The leftover
#     water-fill change touches every workload, so the controls guard against
#     "the branch moved everything for an unrelated reason".
#
# PREREQS -- all three, or the campaign silently measures the wrong thing:
#   1. Both trees on every worker.  Run, in order:
#        ./scripts/distribute_regent.sh --class regent      # fix tree (arm B/C)
#        ./scripts/regent_nursery/distribute_regent_base.sh                # base tree (arm A)
#      distribute_regent_base.sh also writes the .arm_version provenance stamps
#      that sweep_nursery_policy.sh reports and cross-checks.
#   2. sweep_nursery_policy.sh present at
#        ~/working/regent/scripts/working_scripts/sweep_nursery_policy.sh
#      (it ships with the fix tree, so step 1 covers it).
#   3. A running server -- otherwise `j job add` fails and nothing is queued.
#
# Note on machine count: with fewer machines than workloads the jobs simply
# queue and drain in waves.  That costs wall-clock but does NOT weaken the
# comparison -- all 27 cells of a workload run on one machine in one job, so the
# arm contrast is within-machine regardless of how the pool is scheduled.
#
# Results copy back to ./sweep_results_<tag>/ ; track with `j job ls`.
# =============================================================================

CLASS=regent
SWEEP="$HOME/working/regent/scripts/working_scripts/sweep_nursery_policy.sh"
RUN_TAG="${RUN_TAG:-nursery_abc}"
RUNS="$HOME/working/sweep_runs_${RUN_TAG}"                 # per-workload MASTER_DIR root (worker)
CP="./sweep_results_${RUN_TAG}"                            # local aggregation dir (this machine)
J_BIN="${EXPJOBSERVER_CLIENT:-./target/debug/j}"

# Campaign axes; override to extend a running campaign (cells resume, completed
# ones are skipped, so e.g. ITERS=5 adds only iters 4-5 into the same tree).
ITERS="${ITERS:-3}"
# COMMA-separated, not space-separated: the server splits the job command on
# whitespace, so a space here would set RATIOS to "0.2" and pass "0.5" and "1.1"
# to sweep_nursery_policy.sh as positional args.  The sweep script normalises
# the commas back to spaces.
RATIOS="${RATIOS:-0.2,0.5,1.1}"
NURSERY_GRACE="${NURSERY_GRACE:-30}"

# The copier only creates the LEAF dir under $CP -- not its parents.  If $CP is
# missing, every copy-back fails ("mkdir ... No such file or directory"), the
# server counts each as a machine failure, and after MACHINE_FAILURES (4) it
# demotes the machine to "<class>-broken" -- bricking the pool.  Ensure the
# aggregation root exists before queuing anything.
mkdir -p "$CP"

if [[ ! -x "$J_BIN" && -z "$(command -v "$J_BIN")" ]]; then
    echo "ERROR: client not found at '$J_BIN'. Set EXPJOBSERVER_CLIENT." >&2
    exit 1
fi

add_nursery() {                                           # add_nursery <name>
    local w="$1"
    "$J_BIN" job add $CLASS \
        "{MACHINE} env MASTER_DIR=$RUNS/$w ITERS=$ITERS RATIOS=$RATIOS NURSERY_GRACE=$NURSERY_GRACE bash $SWEEP $w" \
        "$CP"
}

# --- the three workloads where REGENT underperformed at constrained ratios ---
for w in renaissance_naive-bayes graph500 npb-cpp_is; do
    add_nursery "$w"
done
# --- negative controls: no starvation symptom, should not move ---------------
for w in gapbs_bc spec_mcf; do
    add_nursery "$w"
done

echo
echo "Queued 5 nursery A/B/C jobs (class=$CLASS, tag=$RUN_TAG)."
echo "  arms:   nursery_base | nursery_fix | nursery_fix_grace30"
echo "  ratios: $RATIOS   iters: $ITERS   grace: ${NURSERY_GRACE} ticks (= ${NURSERY_GRACE}s)"
echo "  135 runs total (5 workloads x 3 arms x 3 ratios x 3 iters)."
echo
echo "Track with:            j job ls"
echo "Results copy back to:  $CP/"
