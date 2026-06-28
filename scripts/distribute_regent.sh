#!/bin/bash

# Distribute regent/workloads updates to already-registered machines.
#
# Pulls the top-level regent and workloads repos in the local deploy directory,
# updates their submodules (except silo, which is patched/built on the machine),
# then rsyncs the source to every registered machine in parallel and rebuilds
# regent. See docs/adr/0001-distribute-script-for-regent-workloads.md.
#
# Usage: distribute_regent.sh [OPTIONS] [HOST ...]

set -euo pipefail

usage() {
    cat << EOF
Usage: $0 [OPTIONS] [HOST ...]

Distribute updated regent/workloads source to registered machines.

Options:
  -d, --deploy <dir>   Local deploy root containing working/{regent,workloads}
                       (default: \$EXPJOBSERVER_DEPLOY_DIR)
      --class <name>   Only target machines in this class
  -j, --jobs <N>       Max machines to update in parallel (default: 8)
      --force          Include machines currently running a job (default: skip)
      --no-build       Skip the regent 'make clean && make' rebuild
      --no-pull        Skip the git pull / submodule update step (sync as-is)
      --staging        Also mirror into the /deploy staging tree (default: skip;
                       only needed to refresh the re-provisioning source)
  -h, --help           Show this help

Positional HOST args restrict distribution to those registered machines.

Environment:
  EXPJOBSERVER_DEPLOY_DIR   Default for --deploy
  EXPJOBSERVER_SSH_USER     SSH user (default: \$(whoami))
  EXPJOBSERVER_SSH_OPTIONS  SSH options
  EXPJOBSERVER_CLIENT       Path to the 'j' client (default: j)

Examples:
  $0 -d ~/school/grad/research/memregion/deploy
  $0 --class hemem -j 16
  $0 c220g5-111326.wisc.cloudlab.us --no-build
EOF
}

# --- Argument parsing -------------------------------------------------------

DEPLOY="${EXPJOBSERVER_DEPLOY_DIR:-}"
CLASS=""
JOBS=8
FORCE=false
NO_BUILD=false
NO_PULL=false
SYNC_STAGING=false
HOSTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--deploy)   DEPLOY="$2"; shift 2 ;;
        --class)       CLASS="$2"; shift 2 ;;
        -j|--jobs)     JOBS="$2"; shift 2 ;;
        --force)       FORCE=true; shift ;;
        --no-build)    NO_BUILD=true; shift ;;
        --no-pull)     NO_PULL=true; shift ;;
        --staging)     SYNC_STAGING=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        -*)            echo "[ERROR] Unknown option: $1" >&2; usage; exit 1 ;;
        *)             HOSTS+=("$1"); shift ;;
    esac
done

if [[ -z "$DEPLOY" ]]; then
    echo "[ERROR] No deploy directory. Pass -d <dir> or set EXPJOBSERVER_DEPLOY_DIR." >&2
    exit 1
fi

REGENT_SRC="$DEPLOY/working/regent"
WORKLOADS_SRC="$DEPLOY/working/workloads"

for d in "$REGENT_SRC" "$WORKLOADS_SRC"; do
    if [[ ! -d "$d/.git" ]]; then
        echo "[ERROR] Not a git repo: $d" >&2
        exit 1
    fi
done

SSH_USER="${EXPJOBSERVER_SSH_USER:-$(whoami)}"
# BatchMode + ConnectTimeout so a host with broken auth or that is unreachable
# fails fast (and reports FAILED) instead of hanging the whole run on a password
# prompt or a dead connection.
SSH_OPTIONS="${EXPJOBSERVER_SSH_OPTIONS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=15}"
J_BIN="${EXPJOBSERVER_CLIENT:-j}"

# Live copy is home-relative (rsynced into $HOME by setup_hemem.sh); staging is
# the absolute path add_machine.sh seeds. Both are kept in sync.
STAGING="/deploy/add_machine/deploy"

# --- Local source prep: pull + submodule update, abort if dirty -------------

prepare_repo() {
    local repo="$1" name="$2"

    # Abort on local (tracked) modifications rather than stash/merge/rebase.
    # Ignore dirty submodule worktrees (notably silo, which is patched/built on
    # the machine and excluded from the pull/rsync below) -- only real tracked
    # or gitlink changes should block.
    if ! git -C "$repo" diff-index --quiet --ignore-submodules=dirty HEAD -- 2>/dev/null; then
        echo "[ERROR] $name has uncommitted changes:" >&2
        git -C "$repo" status --short --untracked-files=no >&2
        echo "[ERROR] Commit or stash them, then re-run." >&2
        return 1
    fi

    echo "[INFO] [$name] git pull --ff-only"
    if ! git -C "$repo" pull --ff-only; then
        echo "[ERROR] $name could not fast-forward (diverged from origin). Resolve manually." >&2
        return 1
    fi

    # Update submodules to their pinned commits, but never touch silo (patched
    # and built on the machine). Refuses to clobber a dirty submodule.
    echo "[INFO] [$name] submodule update (excluding silo)"
    if ! git -C "$repo" -c submodule.silo.update=none submodule update --init --recursive; then
        echo "[ERROR] $name submodule update failed (a submodule may have local edits)." >&2
        return 1
    fi
}

if [[ "$NO_PULL" == "true" ]]; then
    echo "[INFO] --no-pull: skipping git pull / submodule update; syncing local trees as-is."
else
    prepare_repo "$REGENT_SRC" regent || exit 1
    prepare_repo "$WORKLOADS_SRC" workloads || exit 1
fi

# --- Select target machines from the job server -----------------------------

# Parse `j machine ls`: columns are "Machine  Class  Running". A non-empty
# Running column means the machine is busy. ANSI is stripped defensively.
mapfile -t MACHINE_ROWS < <(
    "$J_BIN" machine ls 2>/dev/null \
        | sed -e 's/\x1b\[[0-9;]*m//g' \
        | awk 'NR>1 && $1!="" && $1!="Machine" {print $1"\t"$2"\t"$3}'
)

if [[ ${#MACHINE_ROWS[@]} -eq 0 ]]; then
    echo "[ERROR] No registered machines reported by '$J_BIN machine ls' (is the server running?)." >&2
    exit 1
fi

host_requested() {
    # True if no explicit hosts given, or $1's addr/host matches one of them.
    local addr="$1" h="${1%:*}"
    [[ ${#HOSTS[@]} -eq 0 ]] && return 0
    local want
    for want in "${HOSTS[@]}"; do
        [[ "$addr" == "$want" || "$h" == "$want" || "$h" == "${want%:*}" ]] && return 0
    done
    return 1
}

TARGETS=()        # rows we will distribute to
SKIPPED_BUSY=()   # addrs skipped because busy

for row in "${MACHINE_ROWS[@]}"; do
    IFS=$'\t' read -r addr class running <<< "$row"
    [[ -n "$CLASS" && "$class" != "$CLASS" ]] && continue
    host_requested "$addr" || continue
    if [[ -n "$running" && "$FORCE" != "true" ]]; then
        SKIPPED_BUSY+=("$addr (job $running)")
        continue
    fi
    TARGETS+=("$row")
done

if [[ ${#SKIPPED_BUSY[@]} -gt 0 ]]; then
    echo "[INFO] Skipping busy machines (use --force to include):"
    for s in "${SKIPPED_BUSY[@]}"; do echo "         $s"; done
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "[INFO] No machines to update."
    exit 0
fi

# --- Per-machine work (runs in parallel) ------------------------------------

LOGDIR="./logs/distribute-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGDIR"
echo "[INFO] Distributing to ${#TARGETS[@]} machine(s) (parallelism: $JOBS); per-host logs in $LOGDIR"
echo "[INFO] Targets:"
for row in "${TARGETS[@]}"; do
    IFS=$'\t' read -r _addr _class _ <<< "$row"
    printf '         - %-38s [%s]\n' "$_addr" "$_class"
done

# One-line, timestamped per-host status update.  Hosts run in parallel, so these
# interleave; each printf is a single short write so lines stay intact.
#   RUN  = started (syncing)   BLD = rebuilding regent
#   OK   = finished cleanly    FAIL = failed (see its log)
progress() {
    printf '  %s [%-4s] %-38s %s\n' "$(date +%H:%M:%S)" "$1" "$2" "$3"
}

process_machine() {
    local addr="$1"
    local host port
    if [[ "$addr" == *:* ]]; then host="${addr%:*}"; port="${addr#*:}"; else host="$addr"; port=22; fi
    local remote="$SSH_USER@$host"
    local rsh="ssh $SSH_OPTIONS"
    local ssh_cmd="ssh $SSH_OPTIONS"
    if [[ "$port" != "22" ]]; then rsh="$rsh -p $port"; ssh_cmd="$ssh_cmd -p $port"; fi
    local log="$LOGDIR/$host.log"
    local status="$LOGDIR/$host.status"

    local start end rc
    start=$(date +%s)
    progress "RUN" "$addr" "syncing regent + workloads"
    # Capture the subshell's exit code without letting the script's `set -e` abort
    # process_machine first -- otherwise a failed host never writes its .status and
    # the summary shows NO-STATUS instead of FAILED.
    rc=0
    # fd 3 = console: the work subshell sends its output to the log, but uses fd 3
    # to post the "rebuilding" transition so live progress stays visible.
    exec 3>&1
    (
        set -e
        echo "=== distribute $host @ $(date) ==="

        # regent + workloads -> live (~/working).
        #   --info=progress2  : single overall progress line (percent/rate/ETA) so
        #                       the per-host log shows live transfer progress.
        #   --filter=':- .gitignore' : honor every directory's .gitignore, INCLUDING
        #                       the submodules' own -- so gitignored build artifacts
        #                       and generated datasets (e.g. gapbs's ~45G of binaries
        #                       + benchmark/graphs) are NOT shipped.  The machine
        #                       builds those itself (same model as silo); rsync has
        #                       no --delete, so whatever a machine already built
        #                       stays put.  This cuts a workloads sync ~78G -> ~1.2G.
        # Explicit excludes come before the gitignore filter so .git / silo are
        # always dropped regardless of any .gitignore re-include rules.
        echo "--- rsync regent -> live (~/working/regent) ---"
        rsync -ahz --info=progress2 --mkpath --exclude=.git --filter=':- .gitignore' -e "$rsh" "$REGENT_SRC/" "$remote:working/regent/"
        echo "--- rsync workloads -> live (~/working/workloads) ---"
        rsync -ahz --info=progress2 --mkpath --exclude=.git --exclude='/silo' --filter=':- .gitignore' -e "$rsh" "$WORKLOADS_SRC/" "$remote:working/workloads/"

        if [[ "$SYNC_STAGING" == "true" ]]; then
            # Also mirror into the staging tree add_machine.sh seeds (re-provisioning
            # source).  Off by default -- routine updates only need the live tree.
            echo "--- rsync regent -> staging ($STAGING/working/regent) ---"
            rsync -ahz --info=progress2 --mkpath --exclude=.git --filter=':- .gitignore' -e "$rsh" "$REGENT_SRC/" "$remote:$STAGING/working/regent/"
            echo "--- rsync workloads -> staging ($STAGING/working/workloads) ---"
            rsync -ahz --info=progress2 --mkpath --exclude=.git --exclude='/silo' --filter=':- .gitignore' -e "$rsh" "$WORKLOADS_SRC/" "$remote:$STAGING/working/workloads/"
        fi

        if [[ "$NO_BUILD" != "true" ]]; then
            progress "BLD" "$addr" "rebuilding regent (make clean && make)" >&3
            echo "--- rebuilding regent (make clean && make) ---"
            # login shell so the toolchain is on PATH
            $ssh_cmd "$remote" \
                "bash -lc 'cd working/regent && make clean && make -j\$(nproc)'"
        fi
    ) >"$log" 2>&1 || rc=$?
    exec 3>&-
    end=$(date +%s)

    if [[ $rc -eq 0 ]]; then
        printf 'OK\t%s\n' "$((end - start))" > "$status"
        progress "OK" "$addr" "done in $((end - start))s"
    else
        printf 'FAILED\t%s\t%s\n' "$rc" "$((end - start))" > "$status"
        progress "FAIL" "$addr" "rc=$rc after $((end - start))s -- see $log"
    fi
}

running=0
for row in "${TARGETS[@]}"; do
    IFS=$'\t' read -r addr class running_job <<< "$row"
    process_machine "$addr" &
    running=$((running + 1))
    if (( running >= JOBS )); then
        wait -n
        running=$((running - 1))
    fi
done
wait

# --- Summary ----------------------------------------------------------------

echo ""
echo "===================================================================="
echo " Distribute Summary  -  $(date '+%Y-%m-%d %H:%M:%S')"
echo " Per-host logs: $LOGDIR"
echo "===================================================================="
printf '%-40s %-8s %8s\n' "MACHINE" "STATUS" "TIME"
printf '%-40s %-8s %8s\n' "----------------------------------------" "--------" "--------"

ok=0; failed=0
for row in "${TARGETS[@]}"; do
    IFS=$'\t' read -r addr class running_job <<< "$row"
    host="${addr%:*}"
    statusfile="$LOGDIR/$host.status"
    if [[ -f "$statusfile" ]]; then
        IFS=$'\t' read -r st a b < "$statusfile"
        if [[ "$st" == "OK" ]]; then
            printf '%-40s %-8s %7ss\n' "$addr" "OK" "$a"; ok=$((ok + 1))
        else
            printf '%-40s %-8s %7ss\n' "$addr" "FAILED(rc=$a)" "$b"; failed=$((failed + 1))
        fi
    else
        printf '%-40s %-8s %8s\n' "$addr" "NO-STATUS" "-"; failed=$((failed + 1))
    fi
done
echo "--------------------------------------------------------------------"
echo "Total: ${#TARGETS[@]}   OK: $ok   FAILED: $failed   SKIPPED(busy): ${#SKIPPED_BUSY[@]}"
[[ $failed -gt 0 ]] && echo "Inspect failures in $LOGDIR/<host>.log"

exit $(( failed > 0 ? 1 : 0 ))
