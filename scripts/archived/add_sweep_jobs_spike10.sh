#!/bin/bash
# =============================================================================
# add_sweep_jobs_spike10.sh — queue the "spike floor 10 / bucket boundary 1.0 /
# 5-cluster" campaign onto the SHARED `regent` pool.
# =============================================================================
# Same dispatch mechanics as add_sweep_jobs.sh, with two differences:
#
#   * SWEEP points at the sweep_all_spike10.sh WRAPPER, which sets
#     REGENT_SPIKE_FLOOR_BASE=10, BUCKET_BOUNDARY=1.0, CLUSTERS="1 2 3 4 -1"
#     and then calls the normal sweep_all.sh.  The in-flight campaign uses plain
#     sweep_all.sh, so the two coexist on the same machines with nothing shared
#     edited.
#   * A distinct RUN_TAG => separate sweep_runs_<tag>/ (on the workers) and
#     sweep_results_<tag>/ (here), so no data or results collide with the
#     in-flight campaign.
#
# Coexistence is safe because everything that differs is per-job: the b1.0 lib is
# cache-tagged separately from b1.5, the scheduler runs one job per machine (no
# concurrent `make` race), and spike-floor/boundary ride the wrapper's env.
#
# PREREQ (NOT yet done): the wrapper must be present on every worker at
#   ~/working/regent/scripts/working_scripts/sweep_all_spike10.sh
# Push it with a surgical rsync (same pattern as the plot_profiles.py fix) before
# running this dispatcher, or every job fails immediately ("No such file").
# =============================================================================

CLASS=regent                                              # SHARED pool (interleaves with the bb=1.5 campaign)
SWEEP="$HOME/working/regent/scripts/working_scripts/sweep_all_spike10.sh"
RUN_TAG="${RUN_TAG:-spike10_bb1.0}"                        # distinct tag => brand-new dirs; bump per campaign
RUNS="$HOME/working/sweep_runs_${RUN_TAG}"                 # per-workload MASTER_DIR root (worker, on /dev/sdb)
CP="./sweep_results_${RUN_TAG}"                            # local aggregation dir (this machine)
J_BIN="${EXPJOBSERVER_CLIENT:-j}"

# The copier only creates the LEAF dir under $CP; ensure the root exists first,
# else every copy-back fails and the server demotes machines to <class>-broken.
mkdir -p "$CP"

add_sweep() {                                             # add_sweep <name>: one job per sweep_all name
    local w="$1"
    "$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/$w bash $SWEEP $w" "$CP"
}

# --- identical workload catalog to add_sweep_jobs.sh -------------------------
for w in mcf cactus bwaves deepsjeng mg lbm graph500; do add_sweep "$w"; done
for w in gapbs_bc gapbs_bfs gapbs_cc gapbs_cc_sv gapbs_pr gapbs_pr_spmv gapbs_sssp gapbs_tc; do add_sweep "$w"; done
for w in npb-cpp_cg npb-cpp_is npb-cpp_ft; do add_sweep "$w"; done
for w in renaissance_als renaissance_chi-square renaissance_db-shootout renaissance_dec-tree \
         renaissance_fj-kmeans renaissance_gauss-mix renaissance_log-regression renaissance_movie-lens \
         renaissance_naive-bayes renaissance_page-rank renaissance_scala-kmeans; do add_sweep "$w"; done
for w in spec_xalancbmk spec_fotonik3d spec_roms spec_omnetpp; do add_sweep "$w"; done
for w in spec2026_lbm spec2026_fotonik3d spec2026_roms spec2026_cactus \
         spec2026_omnetpp spec2026_gcc spec2026_zstd; do add_sweep "$w"; done
add_sweep merci
add_sweep xsbench
add_sweep ogb_products
add_sweep micro_interference
add_sweep faiss
add_sweep silo
add_sweep liblinear
add_sweep cloverleaf

echo
echo "Queued spike10_bb1.0 sweep jobs (class=$CLASS, tag=$RUN_TAG). Track with: j job ls"
