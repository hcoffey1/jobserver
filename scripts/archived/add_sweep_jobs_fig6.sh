#!/bin/bash
# =============================================================================
# add_sweep_jobs_fig6.sh — queue the Figure-6 regional-vs-global policy study
# onto the SHARED `regent` pool (on top of the in-flight spike10 campaign).
# =============================================================================
# Same dispatch mechanics as add_sweep_jobs_spike10.sh.  Differences:
#
#   * SWEEP points at sweep_fig6_policy.sh, which runs the full
#     policy(4) x ratio(4) x iter(5) = 80-run grid for ONE workload on ONE node
#     via sweep_simple_freq_compare.sh.  Policies: control (SF), memtis_control
#     (Memtis), cluster_dram_sens_bucket (Binning, bb=1.0), cluster_dram_sens_birch
#     (BIRCH).  Ratios: 0.1 0.25 0.5 2.  Spike10 params (bb=1.0, spike floor 10).
#   * A distinct RUN_TAG => separate sweep_runs_<tag>/ (workers) and
#     sweep_results_<tag>/ (here); nothing collides with spike10 or bwfix.
#
# One workload per node removes cross-node variability from the violins.  Jobs
# interleave with the draining spike10 queue (one job per machine; the b1.0 lib
# is cache-tagged, so no concurrent-make race).
#
# PREREQ: the wrapper must be present on every worker at
#   ~/working/regent/scripts/working_scripts/sweep_fig6_policy.sh
# and the ITERS/RATIOS_OVERRIDE edit to sweep_simple_freq_compare.sh must be
# rsynced too.  Push both before running this dispatcher, or every job fails
# immediately ("No such file" / no ratio expansion).
# =============================================================================

CLASS=regent
SWEEP="$HOME/working/regent/scripts/working_scripts/sweep_fig6_policy.sh"
RUN_TAG="${RUN_TAG:-fig6_regional}"
RUNS="$HOME/working/sweep_runs_${RUN_TAG}"                 # per-workload MASTER_DIR root (worker)
CP="./sweep_results_${RUN_TAG}"                            # local aggregation dir (this machine)
J_BIN="${EXPJOBSERVER_CLIENT:-j}"

# The copier only creates the LEAF dir under $CP; ensure the root exists first.
mkdir -p "$CP"

add_fig6() {                                              # add_fig6 <name>: one job per workload
    local w="$1"
    "$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/$w bash $SWEEP $w" "$CP"
}

# --- the sensitivity/improvement-likely workloads ----------------------------
# Original 5 (high n_eff): graph500, spec_roms, spec_mcf, npb-cpp_is, db-shootout.
# +4 chosen from the spike10 n_eff ranking: naive-bayes (all-rounder), cactuBSSN
# (quadrant-4 showcase, c4=12.6%), gapbs_sssp (fills the gapbs suite gap), and
# gapbs_bfs (n_eff~1 NEGATIVE CONTROL: regional should tie global, no regression).
# +5 more from the refreshed spike10 n_eff ranking (breadth: SPEC2026 suite,
# recognizable page-rank, highest-n_eff gapbs, a new ANN class (faiss), and an
# extreme-sensitivity contrast (xsbench, 98% peak)).
for w in graph500 spec_roms spec_mcf npb-cpp_is renaissance_db-shootout \
         renaissance_naive-bayes spec_cactuBSSN gapbs_sssp gapbs_bfs \
         spec2026_roms renaissance_page-rank gapbs_bc faiss xsbench; do
    add_fig6 "$w"
done

echo
echo "Queued fig6 policy jobs (class=$CLASS, tag=$RUN_TAG). Track with: j job ls"
echo "Results copy back to: $CP/"
