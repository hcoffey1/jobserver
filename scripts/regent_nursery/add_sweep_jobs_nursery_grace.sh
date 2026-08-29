#!/bin/bash
# =============================================================================
# add_sweep_jobs_nursery_grace.sh — two-arm grace-window campaign:
#   control (pre-ADR-0015) vs fallback_nursery at a LONGER demand-grace window.
# =============================================================================
# Follow-up to the nursery_abc campaign (add_sweep_jobs_nursery.sh), which ran
# A/B/C at grace=30 and found the branch mostly costs 2-5% at constrained
# ratios, with arm C (grace=30) beating arm B on spec_mcf and gapbs_bc but
# losing on npb-cpp_is and renaissance_naive-bayes.  That split is why grace is
# worth sweeping rather than abandoning: 30 ticks may simply be too short a
# window for a page to accumulate activation_threshold (50) PEBS samples, so the
# filter prunes demand that was still warming up.
#
# ARMS (2):
#   nursery_base            control -- ~/working/regent_base (hjcoffey/regent)
#   nursery_fix_grace<N>    ~/working/regent (fallback_nursery), grace=N ticks
#
# GRACE UNITS: 1 tick == 1 SECOND (g_tick_counter is bumped by the sleep(1) loop
# in core/regent.cpp), NOT one rebalance window.  GRACE=60 means 60 seconds.
#
# FRESH CONTROL, not reused from nursery_abc.  A distinct RUN_TAG gives brand-new
# per-workload MASTER_DIRs, so the control arm runs again alongside the new grace
# arm on the same machine in the same job, interleaved across iterations.  That
# keeps the comparison within-machine and within-campaign; reusing the earlier
# control would reintroduce exactly the machine/time drift the interleaving is
# there to remove.
#
# GRID: 5 workloads x 2 arms x 3 ratios x 3 iters = 90 runs.
#   ratios 0.2 / 0.5 / 1.1 -- 1.1 is the null control (budget exceeds footprint,
#   so leftover exists and even the control funds the fallback; all arms should
#   converge there).
#   iters 3 -- median + min/max range only.  No distribution claims, no violins.
#
# The grace value is carried in the ARM NAME (nursery_fix_grace60), not an env
# var, so it lands in the results path and --append can never mix two grace
# settings under one directory.  Sweeping more values needs no script change:
#   GRACE=120 ./scripts/regent_nursery/add_sweep_jobs_nursery_grace.sh
#
# PREREQS (same as nursery_abc; both trees must already be on every worker):
#   ./scripts/distribute_regent.sh -d "$HOME" --class regent --no-pull
#   ./scripts/regent_nursery/distribute_regent_base.sh --class regent
# The first is required even if the workers already have a tree: this campaign
# needs the generalised nursery_fix_grace<N> arm in sweep_simple_freq_compare.sh
# and the .arm_version-over-git provenance fix in run_characterization.sh.
# =============================================================================

CLASS=regent
SWEEP="$HOME/working/regent/scripts/working_scripts/sweep_nursery_policy.sh"
GRACE="${GRACE:-60}"                                       # ticks == seconds
RUN_TAG="${RUN_TAG:-nursery_grace${GRACE}}"
RUNS="$HOME/working/sweep_runs_${RUN_TAG}"                 # per-workload MASTER_DIR root (worker)
CP="./sweep_results_${RUN_TAG}"                            # local aggregation dir
J_BIN="${EXPJOBSERVER_CLIENT:-./target/debug/j}"

ITERS="${ITERS:-3}"
# COMMA-separated, both of them: the server splits the job command on
# whitespace, so a space in either value would set the variable to its first
# token and pass the remainder to the sweep script as stray positional args.
RATIOS="${RATIOS:-0.2,0.5,1.1}"
ARMS="${ARMS:-nursery_base,nursery_fix_grace${GRACE}}"

if ! [[ "$GRACE" =~ ^[0-9]+$ ]]; then
    echo "ERROR: GRACE must be a non-negative integer (ticks/seconds), got '$GRACE'" >&2
    exit 1
fi

# The copier only creates the LEAF dir under $CP -- not its parents.  If $CP is
# missing, every copy-back fails ("mkdir ... No such file or directory"), the
# server counts each as a machine failure, and after MACHINE_FAILURES (4) it
# demotes the machine to "<class>-broken" -- bricking the pool.
mkdir -p "$CP"

if [[ ! -x "$J_BIN" && -z "$(command -v "$J_BIN")" ]]; then
    echo "ERROR: client not found at '$J_BIN'. Set EXPJOBSERVER_CLIENT." >&2
    exit 1
fi

add_grace() {                                              # add_grace <workload>
    local w="$1"
    "$J_BIN" job add $CLASS \
        "{MACHINE} env MASTER_DIR=$RUNS/$w ITERS=$ITERS RATIOS=$RATIOS POLICIES=$ARMS bash $SWEEP $w" \
        "$CP"
}

# Same five workloads as nursery_abc: three where the starvation symptom was
# measured, two negative controls that never showed it.
for w in renaissance_naive-bayes graph500 npb-cpp_is gapbs_bc spec_mcf; do
    add_grace "$w"
done

echo
echo "Queued 5 nursery grace jobs (class=$CLASS, tag=$RUN_TAG)."
echo "  arms:   ${ARMS//,/ | }"
echo "  ratios: ${RATIOS//,/ }   iters: $ITERS   grace: ${GRACE} ticks (= ${GRACE}s)"
echo "  90 runs total (5 workloads x 2 arms x 3 ratios x 3 iters)."
echo
echo "Track with:            j job ls"
echo "Results copy back to:  $CP/"
echo "Report:  conda run -n dataVis python scripts/regent_nursery/nursery_report.py $CP -o ./${RUN_TAG}_report"
