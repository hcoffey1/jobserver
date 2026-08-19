#!/bin/bash
# Bootstrap a FRESH control/head node from scratch, provision the worker
# fleet, and end with the jobserver running in THIS terminal (Ctrl-C stops
# it here, like running it by hand -- no tmux, no backgrounding left over).
#
# This is a plain sequential script, not a general-purpose tool: edit the
# variables below and comment out steps you don't need before running it.
# See CLAUDE.md ("First-time setup on a new machine" / "Provisioning a
# fleet") for the full rationale behind each step.
#
# Usage: bash scripts/bootstrap_control_node.sh


# NOTE: Requires ssh -A on the initial connection to control node so we can setup the ssh keys properly later.

set -eux
set -m   # enable job control so `fg` works at the end of this script

# ---- Edit these ------------------------------------------------------------
CLOUDLAB_USER="hjcoffey"          # your CloudLab SSH username
DEPLOY_DIR="/mydata/working"      # deploy root; must end up holding regent/ + workloads/
RSYNC_EXCLUDES="/workloads/liblinear-2.47/kdd12"   # known-good exclude; see CLAUDE.md before adding more
UNATTENDED=true                   # true = mint a local SSH key so overnight runs don't need your forwarded agent
HOST_PATTERN="node*"              # ssh_config Host glob for setup_worker_key.sh (LAN names, not *.cloudlab.us)

# ---- 1. Build the server + client -------------------------------------------
cargo build

# ---- 2. Write local config (gitignored) so the wrapper uses the real user --
echo "export EXPJOBSERVER_SSH_USER=\"$CLOUDLAB_USER\"" > config.local.sh

# ---- 3. Pin the forwarded ssh-agent socket so auth survives reconnects ----
#         (only matters if you later detach this session, e.g. via tmux).
#         New shell (or `source ~/.zshrc`) after this to pick it up.
bash scripts/patches/apply_zshrc_ssh_agent.sh

# ---- 4. Generate machine_list.txt from /etc/hosts (drops the control node) -
bash scripts/gen_machine_list.sh

# ---- 5. (optional) Give the head node its own key for unattended runs -----
#         Must be run while your current forwarded-agent SSH to the workers
#         still works.
if [ "$UNATTENDED" = true ]; then
    EXPJOBSERVER_HOST_PATTERN="$HOST_PATTERN" bash scripts/setup_worker_key.sh
fi

# ---- 6. Start the server, backgrounded in THIS shell for now --------------
#         --allow_snap_fail is required on this very first run only; drop it
#         on every later restart or you discard accumulated job history.
#         Starting the server BEFORE provisioning lets step 10's hosts
#         auto-register instead of reporting SETUP_OK_NO_JOBSERVER.
./target/debug/expjobserver ./expjobserver_remote_wrapper.sh ./logs/ ./example.log.yml --allow_snap_fail &

# ---- 7. Wait for the server to accept client connections ------------------
until ./target/debug/j machine ls >/dev/null 2>&1; do
    sleep 1
done

# ---- 8. Provision + register every host in machine_list.txt --------------
DEPLOY_DIR="$DEPLOY_DIR" \
EXPJOBSERVER_RSYNC_EXCLUDES="$RSYNC_EXCLUDES" \
    bash scripts/setup_all_machines.sh

# ---- 9. Bring the server into the foreground of this terminal ------------
#          It now stays attached here: Ctrl-C stops it, its stdout prints
#          here, same as if you'd run it directly.
fg
