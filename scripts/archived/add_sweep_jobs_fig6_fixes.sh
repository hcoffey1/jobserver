#!/bin/bash
# =============================================================================
# add_sweep_jobs_fig6_fixes.sh — queue the Figure-6 mechanism-fixes re-run
# (ADR-0015 promotion quota + ADR-0016 rebalance damping) onto the `regent` pool.
# =============================================================================
# Same dispatch mechanics as add_sweep_jobs_fig6.sh.  Differences:
#
#   * SWEEP points at sweep_fig6_fixes_policy.sh, which runs the 6-arm long-run
#     grid (4 fixes-off baselines + Binning/BIRCH with both fixes on) x ratio(4)
#     x iter(5) per workload.  naive-bayes additionally carries the 2 ablation
#     arms (quota-only, damp-only) on the same node as its baselines.
#     RENAISSANCE_REPS=60 (longer JVM run so the tiering transient is diluted;
#     same metric extractor).  graph500 stays at -s 26 (scale sets footprint).
#
#   * RUN_TAG=fig6_fixes => its own sweep_runs_fig6_fixes/ (workers) and
#     sweep_results_fig6_fixes/ (here); nothing collides with the fig6_regional
#     baseline campaign, whose SHORT-run data stays the "penalty existed" anchor.
#
#   * A FRESH _libs dir (new tag) forces each worker to rebuild libarms from the
#     wired quota/damping source — otherwise a stale cached .so would ignore the
#     REGENT_PROMOTE_QUOTA env the *_fixed arms set.
#
# PREREQ (push BEFORE running this): the wired regent source + the two edited/new
# scripts must be on every worker at ~/working/regent/ :
#     scripts/working_scripts/sweep_fig6_fixes_policy.sh   (new)
#     scripts/working_scripts/sweep_simple_freq_compare.sh (edited: new arms)
#   and the source that the workers `make` (mechanisms/promotion_quota.*,
#   core/rebalance_damping.*, edited migration.cpp/regent.cpp/Makefile).
#   Use distribute_regent.sh (or an rsync of ~/working/regent) to push them.
# =============================================================================

CLASS=regent
SWEEP="$HOME/working/regent/scripts/working_scripts/sweep_fig6_fixes_policy.sh"
RUN_TAG="${RUN_TAG:-fig6_fixes}"
RUNS="$HOME/working/sweep_runs_${RUN_TAG}"                 # per-workload MASTER_DIR root (worker)
CP="./sweep_results_${RUN_TAG}"                            # local aggregation dir (this machine)
J_BIN="${EXPJOBSERVER_CLIENT:-j}"

# The copier only creates the LEAF dir under $CP; ensure the root exists first.
mkdir -p "$CP"

add_fixes() {                                             # add_fixes <name>: one job per workload
    local w="$1"
    "$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/$w bash $SWEEP $w" "$CP"
}

# All 14 fig6-plottable workloads, queued in PRIORITY order (add-order == queue
# order; the server drains onto the 11-machine pool ~1.3 waves).  One workload
# per node => every arm of a workload (incl. naive-bayes' ablation) runs on one
# machine, free of cross-node variance.
#
# Tier 1 — the diagnosed / biggest-penalty cells the fix most needs to fix
#          (naive-bayes carries the ablation; naive-bayes+graph500 have forensics):
for w in renaissance_naive-bayes graph500 npb-cpp_is renaissance_db-shootout; do
    add_fixes "$w"
done
# Tier 2 — breadth: penalty-likely / high-sensitivity cells not yet fix-tested:
for w in xsbench faiss renaissance_page-rank spec2026_roms gapbs_bc; do
    add_fixes "$w"
done
# Tier 3 — negative controls: regional already ties global here, so these verify
#          the fix does not REGRESS the fits/insensitive cases:
for w in gapbs_sssp gapbs_bfs spec_cactuBSSN spec_roms spec_mcf; do
    add_fixes "$w"
done

echo
echo "Queued fig6-FIXES jobs (class=$CLASS, tag=$RUN_TAG). Track with: j job ls"
echo "Results copy back to: $CP/"
