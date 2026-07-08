#!/bin/bash

# Batch driver for add_machine.sh
#
# Runs scripts/add_machine.sh against every host listed in a machine list file,
# several machines at a time, so a fleet can be provisioned into a stable config
# without babysitting each one sequentially.
#
# Each line of the machine list may be either a bare host or an "ssh user@host"
# line (as copied from CloudLab); only the host part is used. The SSH user comes
# from EXPJOBSERVER_SSH_USER (see below), matching how add_machine.sh resolves it.
#
# NOTE: add_machine.sh's last step is `j machine add`, which talks to a running
# job server. When no server is running (the intended use here) that step fails
# and, because add_machine.sh runs under `set -e`, the whole script exits non-
# zero even though all the real provisioning finished. This driver inspects each
# log and reports that situation as "SETUP_OK_NO_JOBSERVER" rather than a failure.

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# ---- Config (override via environment) -------------------------------------
MACHINE_LIST="${MACHINE_LIST:-machine_list.txt}"
CLASS="${CLASS:-regent}"
SETUP_SCRIPT="${SETUP_SCRIPT:-./scripts/setup_hemem.sh}"
DEPLOY_DIR="${DEPLOY_DIR:-$HOME/school/grad/research/memregion/deploy}"
CONCURRENCY="${CONCURRENCY:-16}"
LOG_DIR="${LOG_DIR:-./setup_run_logs}"

# add_machine.sh reads EXPJOBSERVER_SSH_USER; default to hjcoffey but respect an
# already-exported value.
export EXPJOBSERVER_SSH_USER="${EXPJOBSERVER_SSH_USER:-hjcoffey}"

# add_machine.sh's final `j machine add` uses EXPJOBSERVER_CLIENT to locate the
# client. The 'j' binary is usually NOT on PATH, so default to the built debug
# binary; override to point at a release build or an installed 'j'. Without
# this, registration silently fails and hosts land in SETUP_OK_NO_JOBSERVER.
export EXPJOBSERVER_CLIENT="${EXPJOBSERVER_CLIENT:-./target/debug/j}"

# Extra flags passed through to add_machine.sh (after the deploy dir).
ADD_MACHINE_FLAGS=(-d "$DEPLOY_DIR" -p -v -r)

# ---- Sanity checks ---------------------------------------------------------
if [[ ! -f "$MACHINE_LIST" ]]; then
    echo "[ERROR] Machine list not found: $MACHINE_LIST" >&2
    exit 1
fi
if [[ ! -d "$DEPLOY_DIR" ]]; then
    echo "[ERROR] Deploy dir not found: $DEPLOY_DIR" >&2
    exit 1
fi

mkdir -p "$LOG_DIR"

# ---- Parse host list -------------------------------------------------------
# Accept "ssh user@host", "user@host", or bare "host"; ignore blanks/comments.
mapfile -t HOSTS < <(
    sed -E 's/#.*$//' "$MACHINE_LIST" \
        | awk '{ for (i=1;i<=NF;i++) if ($i ~ /@|\./) { print $i; break } }' \
        | sed -E 's/^.*@//' \
        | sed -E '/^[[:space:]]*$/d'
)

if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "[ERROR] No hosts parsed from $MACHINE_LIST" >&2
    exit 1
fi

echo "==================================================================="
echo " Batch machine setup"
echo "   machines:    ${#HOSTS[@]}"
echo "   concurrency: $CONCURRENCY"
echo "   ssh user:    $EXPJOBSERVER_SSH_USER"
echo "   class:       $CLASS"
echo "   setup:       $SETUP_SCRIPT"
echo "   client:      $EXPJOBSERVER_CLIENT"
echo "   deploy dir:  $DEPLOY_DIR"
echo "   logs:        $LOG_DIR/<host>.log"
echo "==================================================================="
for h in "${HOSTS[@]}"; do echo "   - $h"; done
echo

# ---- Worker ----------------------------------------------------------------
run_one() {
    local host="$1"
    local log="$LOG_DIR/$host.log"
    local status="$LOG_DIR/$host.status"
    local start end rc
    start=$(date +%s)

    echo "[START] $host ($(date '+%H:%M:%S'))"
    ./scripts/add_machine.sh "$host" "$CLASS" "$SETUP_SCRIPT" "${ADD_MACHINE_FLAGS[@]}" \
        >"$log" 2>&1
    rc=$?
    end=$(date +%s)

    local result
    if [[ $rc -eq 0 ]]; then
        result="OK"
    elif grep -q "Setup script finished" "$log" || grep -q "Setup complete" "$log"; then
        # Provisioning ran to completion; the non-zero exit is almost certainly
        # the trailing `j machine add` failing because no job server is running.
        result="SETUP_OK_NO_JOBSERVER"
    else
        result="FAILED(rc=$rc)"
    fi

    printf '%s %s\n' "$result" "$((end - start))" > "$status"
    echo "[DONE ] $host -> $result ($(( (end - start) / 60 ))m$(( (end - start) % 60 ))s)"
}

# ---- Concurrency pool ------------------------------------------------------
for host in "${HOSTS[@]}"; do
    # Throttle: wait until fewer than CONCURRENCY background jobs are running.
    while [[ "$(jobs -rp | wc -l)" -ge "$CONCURRENCY" ]]; do
        wait -n 2>/dev/null || sleep 2
    done
    run_one "$host" &
done

wait
echo

# ---- Summary ---------------------------------------------------------------
echo "==================================================================="
echo " Setup Summary  -  $(date '+%Y-%m-%d %H:%M:%S')"
echo "==================================================================="
printf '%-40s %-22s %8s\n' "HOST" "STATUS" "TIME"
printf '%-40s %-22s %8s\n' "----------------------------------------" "----------------------" "--------"

ok=0; setuponly=0; failed=0
for host in "${HOSTS[@]}"; do
    status_file="$LOG_DIR/$host.status"
    if [[ -f "$status_file" ]]; then
        read -r st secs < "$status_file"
        printf '%-40s %-22s %5dm%02ds\n' "$host" "$st" "$((secs / 60))" "$((secs % 60))"
        case "$st" in
            OK)                    ok=$((ok + 1)) ;;
            SETUP_OK_NO_JOBSERVER) setuponly=$((setuponly + 1)) ;;
            *)                     failed=$((failed + 1)) ;;
        esac
    else
        printf '%-40s %-22s %8s\n' "$host" "NO_STATUS" "-"
        failed=$((failed + 1))
    fi
done

echo "-------------------------------------------------------------------"
echo "Total: ${#HOSTS[@]}   OK: $ok   SetupOnly: $setuponly   FAILED: $failed"
echo "Per-host logs in $LOG_DIR/<host>.log"

# Exit non-zero only if something genuinely failed (SetupOnly is expected here).
[[ $failed -eq 0 ]]
