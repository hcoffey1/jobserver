#!/bin/bash

# Distribute the ARM A baseline regent tree to registered machines.
#
# The fallback-nursery campaign (regent ADR-0015) compares two source trees, so
# each worker needs BOTH:
#
#   ~/working/regent       arm B/C  (hjcoffey/regent_ideas/fallback_nursery)
#                          delivered by distribute_regent.sh, as usual
#   ~/working/regent_base  arm A    (hjcoffey/regent, pre-ADR-0015)
#                          delivered by THIS script
#
# Why a second tree rather than three sequential per-arm waves: with both trees
# present, all 27 cells of a workload run on ONE machine inside ONE job with the
# arms interleaved across iterations, which removes machine identity and
# campaign-time drift as confounds.  See CONTEXT.md "Arm" / "Baseline tree".
#
# This script does NOT build.  run_characterization.sh builds each arm's lib on
# demand into its own per-arm LIB_CACHE_DIR (set by set_policy_env in
# sweep_simple_freq_compare.sh) and caches it for the rest of the campaign.
# Building here would put the .so in the tree, where the next arm's `make clean`
# is irrelevant to it and where nothing reads it.
#
# It also does NOT pull.  The baseline tree is a pinned git worktree -- the whole
# point is that arm A stays fixed at a known commit for the duration of the
# campaign.  Pulling it mid-campaign would silently change what "arm A" means
# between one workload's job and the next.
#
# Usage: distribute_regent_base.sh [OPTIONS] [HOST ...]

set -euo pipefail

usage() {
    cat << EOF
Usage: $0 [OPTIONS] [HOST ...]

Distribute the arm-A baseline regent tree to registered machines.

Options:
  -s, --src <dir>      Local baseline tree (default: \$HOME/working/regent_base)
      --dest <name>    Remote dir under ~/working (default: regent_base)
      --class <name>   Only target machines in this class (default: regent)
  -j, --jobs <N>       Max machines to update in parallel (default: 8)
      --force          Include machines currently running a job (default: skip)
      --no-stamp       Skip writing .arm_version provenance stamps
  -h, --help           Show this help

Positional HOST args restrict distribution to those registered machines.

Environment:
  EXPJOBSERVER_SSH_USER     SSH user (default: \$(whoami))
  EXPJOBSERVER_SSH_OPTIONS  SSH options
  EXPJOBSERVER_CLIENT       Path to the 'j' client (default: j)
  NURSERY_FIX_SRC           Local fix tree to stamp (default: \$HOME/working/regent)

Examples:
  $0                       # all machines in class regent
  $0 node1 --no-stamp
EOF
}

SRC="$HOME/working/regent_base"
DEST_NAME="regent_base"
CLASS="regent"
JOBS=8
FORCE=false
STAMP=true
HOSTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--src)      SRC="$2"; shift 2 ;;
        --dest)        DEST_NAME="$2"; shift 2 ;;
        --class)       CLASS="$2"; shift 2 ;;
        -j|--jobs)     JOBS="$2"; shift 2 ;;
        --force)       FORCE=true; shift ;;
        --no-stamp)    STAMP=false; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
        *)             HOSTS+=("$1"); shift ;;
    esac
done

FIX_SRC="${NURSERY_FIX_SRC:-$HOME/working/regent}"

if [[ ! -f "$SRC/Makefile" ]]; then
    echo "[ERROR] Not a regent checkout (no Makefile): $SRC" >&2
    echo "[ERROR] Create the arm-A worktree first:" >&2
    echo "        git -C $FIX_SRC worktree add $SRC hjcoffey/regent" >&2
    exit 1
fi

SSH_USER="${EXPJOBSERVER_SSH_USER:-$(whoami)}"
SSH_OPTIONS="${EXPJOBSERVER_SSH_OPTIONS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=15}"
J_BIN="${EXPJOBSERVER_CLIENT:-j}"

# --- Provenance stamps ------------------------------------------------------
# rsync runs with --exclude=.git (here and in distribute_regent.sh), so a worker
# tree carries no git metadata and `git rev-parse` there returns nothing.  That
# would leave the sweep log unable to record WHICH COMMIT each arm ran -- the one
# fact this whole campaign hinges on.  So stamp a plain file into each tree; the
# rsync carries it along and sweep_nursery_policy.sh echoes it.
#
# The fix tree is stamped too (though distributed by distribute_regent.sh): the
# stamp is untracked, which prepare_repo's diff-index check ignores and whose
# .gitignore filter still ships, so it rides along on the next distribute.
stamp_tree() {
    local tree="$1" arm="$2"
    local sha branch
    sha="$(git -C "$tree" rev-parse HEAD 2>/dev/null || echo unknown)"
    branch="$(git -C "$tree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    cat > "$tree/.arm_version" <<EOF
arm=$arm
branch=$branch
commit=$sha
stamped=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
stamped_by=$(basename "$0")
EOF
    echo "[INFO] stamped $tree: arm=$arm branch=$branch commit=${sha:0:12}"
}

if [[ "$STAMP" == "true" ]]; then
    stamp_tree "$SRC" "A(base)"
    if [[ -d "$FIX_SRC" ]]; then
        stamp_tree "$FIX_SRC" "B/C(fix)"
    else
        echo "[WARN] fix tree not found at $FIX_SRC; not stamped." >&2
    fi
fi

# --- Select target machines from the job server -----------------------------
# Same `j machine ls` parsing as distribute_regent.sh: columns are
# "Machine  Class  Running"; a non-empty Running column means busy.
mapfile -t MACHINE_ROWS < <(
    "$J_BIN" machine ls 2>/dev/null \
        | sed -e 's/\x1b\[[0-9;]*m//g' \
        | awk 'NR>1 && $1!="" && $1!="Machine" {print $1"\t"$2"\t"$3}'
)

if (( ${#MACHINE_ROWS[@]} == 0 )); then
    echo "[ERROR] No machines from '$J_BIN machine ls'. Is the server running?" >&2
    exit 1
fi

TARGETS=()
for row in "${MACHINE_ROWS[@]}"; do
    IFS=$'\t' read -r addr class running_job <<< "$row"
    [[ -n "$CLASS" && "$class" != "$CLASS" ]] && continue
    if (( ${#HOSTS[@]} > 0 )); then
        local_match=false
        for h in "${HOSTS[@]}"; do [[ "$addr" == "$h" || "${addr%:*}" == "$h" ]] && local_match=true; done
        [[ "$local_match" == "false" ]] && continue
    fi
    if [[ -n "$running_job" && "$FORCE" != "true" ]]; then
        echo "[SKIP] $addr is running a job (use --force to include)"
        continue
    fi
    TARGETS+=("$addr")
done

if (( ${#TARGETS[@]} == 0 )); then
    echo "[ERROR] No target machines selected." >&2
    exit 1
fi

echo "[INFO] Distributing $SRC -> ~/working/$DEST_NAME on ${#TARGETS[@]} machine(s)"

LOGDIR="$(mktemp -d)"

process_machine() {
    local addr="$1"
    local host port
    if [[ "$addr" == *:* ]]; then host="${addr%:*}"; port="${addr#*:}"; else host="$addr"; port=22; fi
    local remote="$SSH_USER@$host"
    local rsh="ssh $SSH_OPTIONS"
    [[ "$port" != "22" ]] && rsh="$rsh -p $port"
    local log="$LOGDIR/$host.log"
    local status="$LOGDIR/$host.status"
    local start end rc
    start=$(date +%s)
    printf '  %s [RUN ] %-38s %s\n' "$(date +%H:%M:%S)" "$addr" "syncing $DEST_NAME"
    rc=0
    (
        set -e
        echo "=== distribute-base $host @ $(date) ==="
        # Same filter model as distribute_regent.sh: drop .git (a FILE, not a
        # dir, in a worktree -- excluded either way) and honor every .gitignore
        # so build artifacts are not shipped.  No --delete: whatever the machine
        # already built stays put.
        rsync -ahz --info=progress2 --mkpath --exclude=.git \
              --filter=':- .gitignore' -e "$rsh" \
              "$SRC/" "$remote:working/$DEST_NAME/"
    ) >"$log" 2>&1 || rc=$?
    end=$(date +%s)
    if [[ $rc -eq 0 ]]; then
        printf 'OK\t%s\n' "$((end - start))" > "$status"
        printf '  %s [OK  ] %-38s %s\n' "$(date +%H:%M:%S)" "$addr" "done in $((end - start))s"
    else
        printf 'FAILED\t%s\t%s\n' "$rc" "$((end - start))" > "$status"
        printf '  %s [FAIL] %-38s %s\n' "$(date +%H:%M:%S)" "$addr" "rc=$rc -- see $log"
    fi
}

running=0
for addr in "${TARGETS[@]}"; do
    process_machine "$addr" &
    running=$((running + 1))
    if (( running >= JOBS )); then wait -n; running=$((running - 1)); fi
done
wait

echo ""
echo "===================================================================="
echo " Distribute-base Summary  -  $(date '+%Y-%m-%d %H:%M:%S')"
echo " Per-host logs: $LOGDIR"
echo "===================================================================="
printf '%-40s %-8s %8s\n' "MACHINE" "STATUS" "TIME"
ok=0; failed=0
for addr in "${TARGETS[@]}"; do
    host="${addr%:*}"
    if [[ -f "$LOGDIR/$host.status" ]]; then
        IFS=$'\t' read -r st a b < "$LOGDIR/$host.status"
        if [[ "$st" == "OK" ]]; then
            printf '%-40s %-8s %7ss\n' "$addr" "OK" "$a"; ok=$((ok+1))
        else
            printf '%-40s %-8s %7ss\n' "$addr" "FAILED" "$b"; failed=$((failed+1))
        fi
    else
        printf '%-40s %-8s %8s\n' "$addr" "NO-STATUS" "-"; failed=$((failed+1))
    fi
done
echo "--------------------------------------------------------------------"
echo " $ok ok, $failed failed"
[[ $failed -gt 0 ]] && exit 1
exit 0
