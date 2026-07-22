#!/bin/bash
# =============================================================================
# add_sweep_jobs_fig6_probe.sh — fast knob probe for the mechanism fixes.
# =============================================================================
# The fig6_fixes campaign showed the fixes REGRESS: the quota was inert (4G >>
# demand) and the damping slew (200M) was too slow to track the allocation ramp.
# This probe re-runs ONLY naive-bayes (fastest clear signal) with re-parameterised
# knobs, at two ratios, using the ablation arms so the two knobs are separable:
#
#     bucket                    baseline (fixes off)          <- reference
#     bucket_quota_only         new quota only                <- does throttling help?
#     bucket_damp_only          new slew only                 <- does relaxed damping recover?
#     bucket_fixed              both new knobs
#   (+ control / memtis / birch* come along in the driver's naive-bayes arm set)
#
# Knob values (env-overridable so you can try other combos without editing):
#     PROBE_QUOTA (FIX_PROMOTE_QUOTA)      default 1G   (was 4G — now BINDS)
#     PROBE_SLEW  (FIX_REBALANCE_MAX_STEP) default 2G   (was 200M — ramps fast)
#
# Two jobs (ratio 0.5 constrained, ratio 2 all-fits), ITERS=3 => ~48 runs total,
# ~1.5 h on two machines.  Distinct RUN_TAG => own results/libs dirs; nothing
# collides with fig6_fixes.  Values pass as single env tokens (no spaces), so the
# jobserver's whitespace command-split is fine.
# =============================================================================

CLASS=regent
DRIVER="$HOME/working/regent/scripts/working_scripts/sweep_fig6_fixes_policy.sh"
RUN_TAG="${RUN_TAG:-fig6_probe}"
RUNS="$HOME/working/sweep_runs_${RUN_TAG}"
CP="./sweep_results_${RUN_TAG}"
J_BIN="${EXPJOBSERVER_CLIENT:-j}"
W=renaissance_naive-bayes

PROBE_QUOTA="${PROBE_QUOTA:-1G}"
PROBE_SLEW="${PROBE_SLEW:-2G}"
PROBE_ITERS="${PROBE_ITERS:-3}"

mkdir -p "$CP"

add_probe() {                                            # add_probe <ratio>
    local r="$1"
    local md="$RUNS/${W}__q${PROBE_QUOTA}_s${PROBE_SLEW}_r${r}"
    "$J_BIN" job add $CLASS \
      "{MACHINE} env MASTER_DIR=$md RATIOS_OVERRIDE=$r ITERS=$PROBE_ITERS FIX_PROMOTE_QUOTA=$PROBE_QUOTA FIX_REBALANCE_MAX_STEP=$PROBE_SLEW bash $DRIVER $W" \
      "$CP"
}

for r in 0.5 2; do
    add_probe "$r"
done

echo
echo "Queued fig6 knob probe (tag=$RUN_TAG): naive-bayes q=$PROBE_QUOTA slew=$PROBE_SLEW"
echo "  ratios 0.5 + 2, ITERS=$PROBE_ITERS.  Track: j job ls   Results: $CP/"
