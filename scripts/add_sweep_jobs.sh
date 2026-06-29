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
RUNS="$HOME/working/sweep_runs"                            # per-workload MASTER_DIR root (remote)
CP=./sweep_results                                        # local aggregation dir (this machine)
J_BIN="${EXPJOBSERVER_CLIENT:-j}"                         # 'j' isn't on PATH by default

# The copier only creates the LEAF dir under $CP -- not its parents.  If $CP is
# missing, every copy-back fails ("mkdir ... No such file or directory") and the
# server demotes the machine to "<class>-broken" after MACHINE_FAILURES.  Ensure
# the aggregation root exists first.
mkdir -p "$CP"

"$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/mcf       bash $SWEEP mcf"       $CP
"$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/cactus    bash $SWEEP cactus"    $CP
"$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/bwaves    bash $SWEEP bwaves"    $CP
"$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/deepsjeng bash $SWEEP deepsjeng" $CP
"$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/mg        bash $SWEEP mg"        $CP
"$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/lbm       bash $SWEEP lbm"       $CP
"$J_BIN" job add $CLASS "{MACHINE} env MASTER_DIR=$RUNS/graph500  bash $SWEEP graph500"  $CP

echo
echo "Queued sweep jobs. Track with:  j job ls"
