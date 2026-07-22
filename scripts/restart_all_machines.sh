#!/bin/bash
# =============================================================================
# restart_all_machines.sh -- reboot every worker attached to the job server
# =============================================================================
# Reboots the worker machines so they come back in a clean state (fresh page
# cache, swap, tmpfs, no leftover processes from prior runs). By default it
# targets every machine reported by `j machine ls`; pass hosts to limit it.
#
# For each host it SSHes in and issues `sudo reboot`. The reboot drops the SSH
# connection (ssh then exits non-zero) -- that is expected and treated as a
# successful trigger. With WAIT_FOR_REBOOT=1 (default) it then polls until the
# host answers SSH again, so the script returns only once the pool is back up.
#
# NOTE: This does NOT re-register machines or touch the job server's machine
# list -- registrations survive a worker reboot. It also does not re-provision.
#
# Usage:  scripts/restart_all_machines.sh [HOST ...]
#   no args : reboot every machine from `j machine ls`
#   HOST... : reboot only those hosts
#
# Env overrides:
#   EXPJOBSERVER_CLIENT   path to 'j'         (default ./target/debug/j)
#   EXPJOBSERVER_SSH_USER ssh user            (default $(whoami))
#   CONCURRENCY           parallel reboots    (default 16)
#   WAIT_FOR_REBOOT       1=wait for return, 0=fire and forget (default 1)
#   REBOOT_WAIT_MAX       seconds to wait per host for return   (default 600)
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

J_BIN="${EXPJOBSERVER_CLIENT:-./target/debug/j}"
SSH_USER="${EXPJOBSERVER_SSH_USER:-$(whoami)}"
CONCURRENCY="${CONCURRENCY:-16}"
WAIT_FOR_REBOOT="${WAIT_FOR_REBOOT:-1}"
REBOOT_WAIT_MAX="${REBOOT_WAIT_MAX:-600}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o BatchMode=yes)

# ---- Target hosts ----------------------------------------------------------
HOSTS=("$@")
if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "[INFO] No hosts given; reading attached machines from '$J_BIN machine ls'"
    # Same parse as setup_worker_key.sh: strip ANSI, take the first column of
    # data rows that look like a hostname, drop any :port.
    mapfile -t HOSTS < <(
        "$J_BIN" machine ls 2>/dev/null \
            | sed -E 's/\x1b\[[0-9;]*m//g' \
            | awk 'NR>1 && $1 ~ /\./ {print $1}' \
            | sed 's/:.*//' \
            | sort -u
    )
fi
if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "[ERROR] No target hosts (pass HOSTs, or start the server so 'j machine ls' works)." >&2
    exit 1
fi

echo "==================================================================="
echo " Rebooting ${#HOSTS[@]} machine(s)   (user: $SSH_USER, wait: $WAIT_FOR_REBOOT)"
echo "==================================================================="
for h in "${HOSTS[@]}"; do echo "   - $h"; done
echo

# ---- Worker ----------------------------------------------------------------
reboot_one() {
    local host="$1"

    # Record the current boot id first, so we can later confirm the machine
    # ACTUALLY rebooted. A failed reboot leaves sshd up and would otherwise look
    # like an instant "return" (false positive).
    local before
    before="$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)"

    # Trigger the reboot. Use `sudo -n` so sudo never tries to prompt for a
    # password over the TTY-less batch ssh -- plain `sudo reboot` silently no-ops
    # on hosts where that prompt can't be shown. The connection drops as the host
    # goes down, so a non-zero exit here is normal -- don't treat it as a failure.
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" 'sudo -n reboot' >/dev/null 2>&1 || true
    echo "[SENT ] reboot -> $host"

    if [[ "$WAIT_FOR_REBOOT" != "1" ]]; then
        return 0
    fi

    # Give the host a moment to actually start going down before we poll, so we
    # don't mistake the still-up pre-reboot sshd for "already back".
    sleep 20

    local waited=0
    while [[ $waited -lt $REBOOT_WAIT_MAX ]]; do
        # Reachable AND a NEW boot id => a real reboot completed. Comparing boot
        # ids (not just "ssh works") is what prevents a false "back online" when
        # the reboot never actually happened.
        local after
        after="$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)"
        if [[ -n "$after" && "$after" != "$before" ]]; then
            echo "[UP   ] $host (rebooted, back after ~$((waited + 20))s)"
            return 0
        fi
        sleep 10
        waited=$((waited + 10))
    done
    echo "[TIMEOUT] $host did not confirm a fresh boot within $((REBOOT_WAIT_MAX + 20))s" >&2
    return 1
}

# ---- Concurrency pool ------------------------------------------------------
declare -A RC
for host in "${HOSTS[@]}"; do
    while [[ "$(jobs -rp | wc -l)" -ge "$CONCURRENCY" ]]; do
        wait -n 2>/dev/null || sleep 2
    done
    reboot_one "$host" &
    RC["$host"]=$!
done

# ---- Collect results -------------------------------------------------------
fails=0
for host in "${HOSTS[@]}"; do
    if ! wait "${RC[$host]}"; then
        fails=$((fails + 1))
    fi
done

echo
if [[ $fails -eq 0 ]]; then
    if [[ "$WAIT_FOR_REBOOT" == "1" ]]; then
        echo "[DONE] All ${#HOSTS[@]} machine(s) rebooted and back online."
    else
        echo "[DONE] Reboot issued to all ${#HOSTS[@]} machine(s) (not waiting)."
    fi
else
    echo "[DONE with $fails issue(s)] Some machines did not come back in time." >&2
fi
exit $(( fails > 0 ? 1 : 0 ))
