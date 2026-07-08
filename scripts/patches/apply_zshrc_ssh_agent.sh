#!/bin/bash
# =============================================================================
# apply_zshrc_ssh_agent.sh -- install the forwarded-agent pin into ~/.zshrc
# =============================================================================
# Inserts (or refreshes) the managed block in scripts/patches/zshrc_ssh_agent.snippet
# so that detached tmux sessions -- the expjobserver head node -- keep worker
# SSH access after you disconnect/reconnect. See the snippet header for why.
#
# Idempotent: re-running replaces the existing managed block in place, so it is
# safe to run repeatedly and to pull the latest snippet and re-apply.
#
# Usage:  scripts/patches/apply_zshrc_ssh_agent.sh
#
# Env overrides:
#   ZSHRC     target rc file   (default ~/.zshrc)
#   SNIPPET   block to install (default scripts/patches/zshrc_ssh_agent.snippet)
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

ZSHRC="${ZSHRC:-$HOME/.zshrc}"
SNIPPET="${SNIPPET:-$HERE/zshrc_ssh_agent.snippet}"

MARK_BEGIN="# >>> expjobserver ssh-agent pin (managed by apply_zshrc_ssh_agent.sh) >>>"
MARK_END="# <<< expjobserver ssh-agent pin <<<"

if [[ ! -f "$SNIPPET" ]]; then
    echo "[ERROR] Snippet not found: $SNIPPET" >&2
    exit 1
fi

touch "$ZSHRC"

if grep -qF "$MARK_BEGIN" "$ZSHRC"; then
    # Refresh: drop the old managed block, then append the current snippet.
    tmp="$(mktemp)"
    awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
        $0==b {skip=1} !skip {print} $0==e {skip=0}' "$ZSHRC" > "$tmp"
    # Trim a trailing blank line the removal may leave, then append.
    printf '\n' >> "$tmp"
    cat "$SNIPPET" >> "$tmp"
    mv "$tmp" "$ZSHRC"
    echo "[INFO] Refreshed managed block in $ZSHRC"
else
    printf '\n' >> "$ZSHRC"
    cat "$SNIPPET" >> "$ZSHRC"
    echo "[INFO] Appended managed block to $ZSHRC"
fi

echo "[DONE] Open a new shell (or 'source $ZSHRC') to activate."
echo "       Verify with:  ls -l ~/.ssh/agent.sock && ssh-add -l"
