#!/bin/bash
# =============================================================================
# add_all_machines.sh -- register every host in a machine list with the server
# =============================================================================
# Reads a machine list (default machine_list.txt), parses the hostnames, and
# runs `j machine add <host> <class>` for each. This ONLY registers already-
# provisioned machines with a running job server; it does no provisioning
# itself (that is add_machine.sh / setup_all_machines.sh).
#
# Each line may be a bare host, "user@host", or an "ssh user@host" line (as
# copied from CloudLab); only the host part is used.
#
# Usage:  scripts/add_all_machines.sh
#
# Env overrides:
#   MACHINE_LIST         list file            (default machine_list.txt)
#   CLASS                class to register as (default regent)
#   EXPJOBSERVER_CLIENT  path to 'j'          (default ./target/debug/j; 'j' is
#                                              usually NOT on PATH)
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

MACHINE_LIST="${MACHINE_LIST:-machine_list.txt}"
CLASS="${CLASS:-regent}"
J_BIN="${EXPJOBSERVER_CLIENT:-./target/debug/j}"

# ---- Sanity checks ---------------------------------------------------------
if [[ ! -f "$MACHINE_LIST" ]]; then
    echo "[ERROR] Machine list not found: $MACHINE_LIST" >&2
    exit 1
fi
if [[ ! -x "$J_BIN" ]] && ! command -v "$J_BIN" >/dev/null 2>&1; then
    echo "[ERROR] Client not found/executable: $J_BIN" >&2
    echo "        Build it (cargo build) or set EXPJOBSERVER_CLIENT." >&2
    exit 1
fi

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

# Confirm the server is reachable before we start.
if ! "$J_BIN" machine ls >/dev/null 2>&1; then
    echo "[ERROR] Cannot reach the job server via '$J_BIN'. Is it running?" >&2
    exit 1
fi

echo "Registering ${#HOSTS[@]} machine(s) as class '$CLASS' via $J_BIN"

# ---- Register --------------------------------------------------------------
added=0; failed=0
for h in "${HOSTS[@]}"; do
    if "$J_BIN" machine add "$h" "$CLASS" >/dev/null 2>&1; then
        echo "  [OK]   $h"
        added=$((added + 1))
    else
        echo "  [FAIL] $h" >&2
        failed=$((failed + 1))
    fi
done

echo
echo "Added: $added   Failed: $failed"
echo "==== j machine ls ===="
"$J_BIN" machine ls 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g'

[[ $failed -eq 0 ]]
