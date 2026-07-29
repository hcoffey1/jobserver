#!/bin/bash
# =============================================================================
# setup_worker_key.sh — give the job-server head node its OWN key to the workers
# =============================================================================
# The server, its SSH wrapper (expjobserver_remote_wrapper.sh), and the results
# copier all reach the worker machines over SSH using whatever identity the
# ssh-agent offers. Today that is YOUR FORWARDED agent -- when you disconnect,
# the forwarded socket dies and the server loses ALL worker access: new jobs and
# result copy-back fail with `publickey`. For overnight / unattended runs the
# head node needs a LOCAL key the workers trust, independent of your laptop.
#
# Run this ONCE, while you still have working SSH to the workers. It:
#   1. creates a dedicated local keypair ~/.ssh/id_jobserver (no passphrase, so
#      it works unattended) if one doesn't already exist,
#   2. installs its public half into each worker's authorized_keys via
#      ssh-copy-id (using your CURRENT/forwarded access), and
#   3. writes a managed ~/.ssh/config block so every ssh/scp/rsync to the worker
#      hostnames uses that key -- which transparently fixes BOTH the wrapper and
#      the copier with no code change.
#
# After this you can detach the tmux server and disconnect; the head node keeps
# its own access to the workers. (The agent-forwarding setup can stay for your
# own interactive logins; the server no longer depends on it.)
#
# Usage:  setup_worker_key.sh [HOST ...]
#   no args : target the hosts in $MACHINE_LIST if that file exists, else every
#             machine reported by `j machine ls`
#   HOST... : target only those hosts
#
# The machine-list fallback matters because this script is normally run BEFORE
# the server is up (that is the whole point -- get the head node its own key
# first), so `j machine ls` has nothing to report yet.
#
# Env overrides:
#   EXPJOBSERVER_KEY           key path           (default ~/.ssh/id_jobserver)
#   EXPJOBSERVER_SSH_USER      ssh user           (default $(whoami))
#   EXPJOBSERVER_HOST_PATTERN  ssh_config Host glob(default *.cloudlab.us)
#   EXPJOBSERVER_CLIENT        path to 'j'        (default j)
#   MACHINE_LIST               host list file     (default machine_list.txt)
# =============================================================================
set -euo pipefail

KEY="${EXPJOBSERVER_KEY:-$HOME/.ssh/id_jobserver}"
SSH_USER="${EXPJOBSERVER_SSH_USER:-$(whoami)}"
J_BIN="${EXPJOBSERVER_CLIENT:-j}"
HOST_PATTERN="${EXPJOBSERVER_HOST_PATTERN:-*.cloudlab.us}"
SSH_CONFIG="$HOME/.ssh/config"
# Resolved relative to the repo root, like the other scripts' default.
MACHINE_LIST="${MACHINE_LIST:-$(cd "$(dirname "$0")/.." && pwd)/machine_list.txt}"

# --- 1. Local keypair --------------------------------------------------------
if [[ -f "$KEY" ]]; then
    echo "[INFO] Reusing existing key $KEY"
else
    echo "[INFO] Generating dedicated key $KEY (ed25519, no passphrase -> unattended)"
    ssh-keygen -t ed25519 -N "" -C "expjobserver@$(hostname -s)" -f "$KEY"
fi

# --- 2. Target hosts ---------------------------------------------------------
HOSTS=("$@")
if [[ ${#HOSTS[@]} -eq 0 && -f "$MACHINE_LIST" ]]; then
    echo "[INFO] No hosts given; reading $MACHINE_LIST"
    # Same parse as setup_all_machines.sh: drop comments, take the first field
    # that looks like a host ('@' or '.'), strip any user@ prefix.
    mapfile -t HOSTS < <(
        sed -E 's/#.*$//' "$MACHINE_LIST" \
            | awk '{ for (i=1;i<=NF;i++) if ($i ~ /@|\./) { print $i; break } }' \
            | sed -E 's/^.*@//' \
            | sed -E '/^[[:space:]]*$/d'
    )
fi
if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "[INFO] Falling back to registered machines from '$J_BIN machine ls'"
    # Strip ANSI, skip the title row, take the first column, drop any :port.
    # NOTE: do NOT require a '.' in the hostname -- on a LAN-addressed fleet the
    # machines are registered as bare names like 'node1' and a dot-filter drops
    # every one of them.
    mapfile -t HOSTS < <(
        "$J_BIN" machine ls 2>/dev/null \
            | sed -E 's/\x1b\[[0-9;]*m//g' \
            | awk 'NR>1 && $1 != "" && $1 !~ /^-+$/ {print $1}' \
            | sed 's/:.*//' \
            | sort -u
    )
fi
if [[ ${#HOSTS[@]} -eq 0 ]]; then
    echo "[ERROR] No target hosts. Pass HOSTs, create $MACHINE_LIST" >&2
    echo "        (scripts/gen_machine_list.sh), or start the server so 'j machine ls' works." >&2
    exit 1
fi

# The managed ssh_config block is keyed on a Host glob. If it does not match the
# hosts we just installed the key on, the block is inert: ssh/scp/rsync keep
# using the (forwarded, soon-dead) agent and the overnight run still breaks --
# silently, since every step here would still report success.
for h in "${HOSTS[@]}"; do
    # shellcheck disable=SC2053  # intentional glob match, not a string compare
    if [[ "$h" != $HOST_PATTERN ]]; then
        echo "[WARN] Host '$h' does NOT match EXPJOBSERVER_HOST_PATTERN '$HOST_PATTERN';" >&2
        echo "       the ~/.ssh/config block below will not apply to it." >&2
        echo "       For bare LAN names, re-run with EXPJOBSERVER_HOST_PATTERN='node*'." >&2
        break
    fi
done
echo "[INFO] Installing key on ${#HOSTS[@]} host(s): ${HOSTS[*]}"

# --- 3. Install pubkey using your current (forwarded) access -----------------
fails=0
for h in "${HOSTS[@]}"; do
    echo "[INFO] ssh-copy-id -> $SSH_USER@$h"
    if ssh-copy-id -i "${KEY}.pub" -o StrictHostKeyChecking=accept-new "$SSH_USER@$h"; then
        # Verify the new key authenticates ON ITS OWN (not via the agent), which
        # is exactly the disconnected-overnight condition.
        if ssh -i "$KEY" -o IdentitiesOnly=yes -o BatchMode=yes \
               -o StrictHostKeyChecking=accept-new "$SSH_USER@$h" true 2>/dev/null; then
            echo "       OK (local key authenticates without the agent)"
        else
            echo "       WARN: key copied but standalone login did not verify on $h" >&2
            fails=$((fails + 1))
        fi
    else
        echo "       FAIL: could not install key on $h (is your current SSH to it working?)" >&2
        fails=$((fails + 1))
    fi
done

# --- 4. Wire ssh/scp/rsync to use the local key for the workers --------------
# A managed block in ~/.ssh/config makes the wrapper (ssh/scp) AND the copier
# (rsync -e ssh) use this key with no code change. IdentitiesOnly=yes pins it so
# a (possibly empty/dead) agent never gets in the way.
MARK_BEGIN="# >>> expjobserver worker key (managed by setup_worker_key.sh) >>>"
MARK_END="# <<< expjobserver worker key <<<"
block="$MARK_BEGIN
Host $HOST_PATTERN
    User $SSH_USER
    IdentityFile $KEY
    IdentitiesOnly yes
$MARK_END"

touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
if grep -qF "$MARK_BEGIN" "$SSH_CONFIG"; then
    tmp="$(mktemp)"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0==b {skip=1} !skip {print} $0==e {skip=0}' "$SSH_CONFIG" > "$tmp"
    printf '%s\n' "$block" >> "$tmp"
    mv "$tmp" "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
    echo "[INFO] Refreshed managed block in $SSH_CONFIG"
else
    printf '\n%s\n' "$block" >> "$SSH_CONFIG"
    echo "[INFO] Appended managed block to $SSH_CONFIG"
fi

echo
if [[ $fails -eq 0 ]]; then
    echo "[DONE] Head node now has its own key to every target. Safe to disconnect."
else
    echo "[DONE with $fails issue(s)] Fix SSH to the failed host(s) and re-run (idempotent)." >&2
fi
echo "        ~/.ssh/config: Host $HOST_PATTERN -> IdentityFile $KEY  (covers wrapper + copier)"
exit $(( fails > 0 ? 1 : 0 ))
