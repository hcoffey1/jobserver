#!/bin/bash
# =============================================================================
# add_sweep_jobs.sh — queue one job-server job per sweep_all.sh workload.
# =============================================================================
# Each line below schedules ONE workload sweep as its own job. The server hands
# each job to whichever free `regent` machine it picks, so the seven workloads
# spread across the machine pool automatically (one benchmark per machine at a
# time). Comment out a line to skip that workload.
#
# Each job runs, on the chosen machine:
#     env MASTER_DIR=<per-workload dir> bash <sweep_all.sh> <workload>
#
#   * MASTER_DIR is FIXED per workload (predictable path, and re-running the job
#     RESUMES -- completed sweep cells are skipped). It holds results only; the
#     shared bucket-lib build lives elsewhere (see LIB_CACHE_DIR in sweep_all.sh).
#   * sweep_all.sh prints its own "RESULTS: $MASTER_DIR/" line, so the server
#     rsyncs that directory back to this machine.
#
# Results AGGREGATE here under $CP/ -- each workload lands in its own uniquely
# named subdir, e.g.:
#     ./sweep_results/spec_mcf/   ./sweep_results/spec_cactuBSSN/
#     ./sweep_results/graph500/   ./sweep_results/npb-cpp_mg/   ...
#
# Track progress:   j job ls
# Inspect one job:  j job stat <id>      (logs under ./logs/<id>*)
# These sweeps are long (~6-12h each at the default axes); the scheduler runs
# them as machines free up.
# =============================================================================

CLASS=regent                                              # matches registered machines
SWEEP="$HOME/working/regent/scripts/working_scripts/sweep_all.sh"
# RUN_TAG names this campaign.  A FRESH tag => brand-new per-workload MASTER_DIRs
# that don't exist on any machine yet, so every job starts from scratch wherever
# the scheduler places it (machine assignment no longer matters) and the previous
# run's data/results are left untouched.  Bump the tag for each new campaign.
RUN_TAG="${RUN_TAG:-3iter}"
RUNS="$HOME/working/sweep_runs_${RUN_TAG}"                 # per-workload MASTER_DIR root (remote, on /dev/sdb via ~/working symlink)
CP="./sweep_results_${RUN_TAG}"                            # local aggregation dir (this machine)
J_BIN="${EXPJOBSERVER_CLIENT:-j}"                         # 'j' isn't on PATH by default

# The copier only creates the LEAF dir under $CP -- not its parents.  If $CP is
# missing, every copy-back fails ("mkdir ... No such file or directory") and the
# server demotes the machine to "<class>-broken" after MACHINE_FAILURES.  Ensure
# the aggregation root exists first.
mkdir -p "$CP"

add_sweep() {                                             # add_sweep <name>: one job per sweep_all name
    local w="$1"
    "$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/$w bash $SWEEP $w" "$CP"
}

# --- Original memory-intensive core (SPEC + npb mg + graph500) ---------------
for w in mcf cactus bwaves deepsjeng mg lbm graph500; do add_sweep "$w"; done

# --- Expanded catalog (parsed from smoke_results; metrics per ADR-0013) ------
# Each is scheduled as its own job; comment out a line/loop to skip a workload.
# gapbs graph kernels (twitter, ~12-23 GB) -- metric: built-in "Average Time"
for w in gapbs_bc gapbs_bfs gapbs_cc gapbs_cc_sv gapbs_pr gapbs_pr_spmv gapbs_sssp gapbs_tc; do add_sweep "$w"; done
# NPB-CPP kernels -- dual metric (time + Mop/s).  ft ~80 GB / is ~33 GB: big-footprint,
# schedule on a DRAM node sized for ~peak (like mg/graph500).
for w in npb-cpp_cg npb-cpp_is npb-cpp_ft; do add_sweep "$w"; done
# renaissance JVM benchmarks (~0.7-15 GB) -- metric: per-iteration ms, warmup-skipped
for w in renaissance_als renaissance_chi-square renaissance_db-shootout renaissance_dec-tree \
         renaissance_fj-kmeans renaissance_gauss-mix renaissance_log-regression renaissance_movie-lens \
         renaissance_naive-bayes renaissance_page-rank renaissance_scala-kmeans; do add_sweep "$w"; done
# more SPEC CPU2017 refrate (sub-1 GB) -- metric: walltime
for w in spec_xalancbmk spec_fotonik3d spec_roms spec_omnetpp; do add_sweep "$w"; done
# SPEC CPU2026 (cpuv8) refrate subset (sub-2 GB) -- metric: walltime.  The suite
# is NOT prebuilt on the workers: the first spec2026 job to land on a machine
# auto-installs + builds it from the ISO (scripts/workloads/spec2026.sh), so that
# machine's first job runs ~45 min longer, then later spec2026 jobs reuse it.
# omnetpp/gcc/zstd are multi-invocation (10/3/8 sub-runs, summed walltime).
for w in spec2026_lbm spec2026_fotonik3d spec2026_roms spec2026_cactus \
         spec2026_omnetpp spec2026_gcc spec2026_zstd; do add_sweep "$w"; done
# singletons.  liblinear ~69 GB / xsbench ~63 GB: big-footprint (see NPB note).
add_sweep merci
add_sweep xsbench
add_sweep ogb_products
add_sweep micro_interference        # throughput (ops/s), NOT walltime (fixed 60s run)
add_sweep faiss                     # walltime
add_sweep silo                      # walltime
add_sweep liblinear                 # walltime
add_sweep cloverleaf                # walltime

echo
echo "Queued sweep jobs. Track with:  j job ls"
