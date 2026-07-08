#!/bin/bash


# Machine Setup Helper for Expjobserver
# Usage: add_machine.sh <machine> <class> <script> [-d <deploy_dir>]

set -euo pipefail

# Path to the 'j' client. Override with EXPJOBSERVER_CLIENT when 'j' is not on
# PATH (e.g. point it at ./target/debug/j). Matches setup_worker_key.sh.
J_BIN="${EXPJOBSERVER_CLIENT:-j}"

# Wait for remote machine to reboot and come back online
wait_for_reboot() {
    local SSH_CMD="$1"
    local REMOTE="$2"
    local MAX_WAIT="${3:-600}"  # 10 minutes max wait by default
    local WAIT_COUNT=0
    echo "[INFO] Waiting for machine to reboot and come back online..."
    sleep 30  # Initial wait for reboot to start
    while [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
        # Use ConnectTimeout and a short command to test SSH readiness
        if $SSH_CMD -o ConnectTimeout=5 $REMOTE "echo 'Machine is back online'" 2>/dev/null; then
            echo "[INFO] Machine is back online after $((WAIT_COUNT + 30)) seconds"
            # Give sshd and systemd services a moment to fully stabilize
            sleep 5
            return 0
        fi
        echo "[INFO] Waiting for machine to come back online... ($((WAIT_COUNT + 30))s)"
        sleep 15
        WAIT_COUNT=$((WAIT_COUNT + 15))
    done
    echo "[ERROR] Machine did not come back online within $((MAX_WAIT + 30)) seconds"
    return 1
}

usage() {
    cat << EOF
Usage: $0 <machine> <class> <script> [OPTIONS]

Arguments:
  machine              Machine identifier (used for SSH connection)
  class                Machine class to assign
  script               Local script to upload and execute on remote machine

Options:
  -d, --deploy <dir>   Path to local deployment directory to copy to remote
  -r, --reinstall      Delete existing remote base directory before setup
  -v, --verbose        Include .git directories in rsync (default: excluded)
  -p, --resize-partition  Resize root partition to use full disk before setup
  -h, --help           Show this help

Examples:
  $0 cloudlab.us foo ./templates/setup_env.sh -d ./deploy_dir
  $0 cloudlab.us foo ./setup.sh --reinstall --verbose
  $0 machine:2222 compute ./configure.sh -d ./app -r
  $0 cloudlab.us gpu ./setup.sh --resize-partition
EOF
}

if [[ $# -lt 3 ]]; then
    usage
    exit 1
fi

MACHINE="$1"
CLASS="$2"
SCRIPT="$3"
shift 3
DEPLOY=""
REINSTALL=false
VERBOSE=false
RESIZE_PARTITION=false

# Parse optional arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--deploy)
            DEPLOY="$2"
            shift 2
            ;;
        -r|--reinstall)
            REINSTALL=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -p|--resize-partition)
            RESIZE_PARTITION=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# SSH and rsync setup
DEFAULT_SSH_USER="${EXPJOBSERVER_SSH_USER:-$(whoami)}"
DEFAULT_SSH_OPTIONS="${EXPJOBSERVER_SSH_OPTIONS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"

if [[ "$MACHINE" == *":"* ]]; then
    MACHINE_HOST="${MACHINE%:*}"
    MACHINE_PORT="${MACHINE#*:}"
else
    MACHINE_HOST="$MACHINE"
    MACHINE_PORT="22"
fi

SSH_CMD="ssh $DEFAULT_SSH_OPTIONS"

# Setup rsync command with .git exclusion by default
RSYNC_EXCLUDES=""
if [[ "$VERBOSE" != "true" ]]; then
    RSYNC_EXCLUDES="--exclude=.git --exclude=.gitignore"
    echo "[INFO] Excluding .git directories from rsync (use --verbose to include)"
else
    echo "[INFO] Including .git directories in rsync (verbose mode)"
fi

RSYNC_CMD="rsync -ahz --info=progress2 $RSYNC_EXCLUDES"
if [[ "$MACHINE_PORT" != "22" ]]; then
    SSH_CMD="$SSH_CMD -p $MACHINE_PORT"
    RSYNC_CMD="$RSYNC_CMD -e 'ssh $DEFAULT_SSH_OPTIONS -p $MACHINE_PORT'"
else
    RSYNC_CMD="$RSYNC_CMD -e 'ssh $DEFAULT_SSH_OPTIONS'"
fi
REMOTE="$DEFAULT_SSH_USER@$MACHINE_HOST"

# Prepare remote paths
REMOTE_BASE="/deploy/add_machine"
REMOTE_SCRIPT="$REMOTE_BASE/$(basename "$SCRIPT")"
REMOTE_DEPLOY="$REMOTE_BASE/deploy"
REMOTE_LOG="$REMOTE_BASE/setup.log"

# Handle reinstall option
if [[ "$REINSTALL" == "true" ]]; then
    echo "[INFO] Reinstall mode: Removing existing remote base directory"
    $SSH_CMD $REMOTE "sudo rm -rf '$REMOTE_BASE'"
fi

echo "[INFO] Creating remote base directory: $REMOTE_BASE"
$SSH_CMD $REMOTE "sudo mkdir -p '$REMOTE_BASE' && sudo chown $DEFAULT_SSH_USER '$REMOTE_BASE'"

# Handle partition resize if requested
if [[ "$RESIZE_PARTITION" == "true" ]]; then
    echo "[INFO] Resize partition requested - uploading and running resize script"
    
    # Check if resize script exists
    RESIZE_SCRIPT="./scripts/resize_remote_partition.sh"
    if [[ ! -f "$RESIZE_SCRIPT" ]]; then
        echo "[ERROR] Resize script not found at $RESIZE_SCRIPT"
        exit 1
    fi
    
    # Upload resize script
    REMOTE_RESIZE_SCRIPT="$REMOTE_BASE/resize_remote_partition.sh"
    echo "[INFO] Copying resize script to remote machine"
    eval $RSYNC_CMD "$RESIZE_SCRIPT" "$REMOTE:$REMOTE_RESIZE_SCRIPT"
    
    # Execute resize script (this will reboot the machine if needed)
    echo "[INFO] Executing resize script on remote machine (may reboot the machine)"
    $SSH_CMD $REMOTE "chmod +x '$REMOTE_RESIZE_SCRIPT' && '$REMOTE_RESIZE_SCRIPT'" || {
        echo "[INFO] SSH connection lost - this is expected as the machine reboots"
        wait_for_reboot "$SSH_CMD" "$REMOTE" || exit 1

        # The resize script installs a post-boot systemd service that handles
        # filesystem growth and swapfile setup. Wait for it to finish by
        # polling for the marker file it creates on completion.
        echo "[INFO] Waiting for post-boot resize service to complete..."
        RESIZE_WAIT=0
        RESIZE_MAX=300  # 5 minutes
        while [[ $RESIZE_WAIT -lt $RESIZE_MAX ]]; do
            if $SSH_CMD $REMOTE "test -f /var/lib/rootfs-resizer/done" 2>/dev/null; then
                echo "[INFO] Post-boot resize service completed successfully"
                break
            fi
            echo "[INFO] Resize service still running... ($((RESIZE_WAIT))s)"
            sleep 10
            RESIZE_WAIT=$((RESIZE_WAIT + 10))
        done

        if [[ $RESIZE_WAIT -ge $RESIZE_MAX ]]; then
            echo "[WARN] Timed out waiting for resize service, checking status..."
        fi

        # Show final state
        $SSH_CMD $REMOTE "echo '=== Final filesystem size ===' && df -h / && echo && lsblk"
        echo "[INFO] Partition resize completed"
    }
fi

# Copy script
echo "[INFO] Copying script $SCRIPT to $REMOTE_SCRIPT"
eval $RSYNC_CMD "$SCRIPT" "$REMOTE:$REMOTE_SCRIPT"

# Copy deployment directory if provided
if [[ -n "$DEPLOY" && -d "$DEPLOY" ]]; then
    echo "[INFO] Copying deployment directory $DEPLOY to $REMOTE_DEPLOY"
    eval $RSYNC_CMD "$DEPLOY/" "$REMOTE:$REMOTE_DEPLOY/"
fi

# Run the setup script in a tmux session so it persists if the local terminal disconnects.
# The script logs to $REMOTE_LOG; we can follow progress or detach safely.

TMUX_SESSION="add_machine_setup"

echo "[INFO] Launching setup script in tmux session '$TMUX_SESSION' on remote (logging to $REMOTE_LOG)"
$SSH_CMD $REMOTE "chmod +x '$REMOTE_SCRIPT' && \
    tmux kill-session -t '$TMUX_SESSION' 2>/dev/null || true && \
    tmux new-session -d -s '$TMUX_SESSION' \
        \"cd '$REMOTE_BASE' && '$REMOTE_SCRIPT' > '$REMOTE_LOG' 2>&1; echo SETUP_DONE >> '$REMOTE_LOG'\""

echo "[INFO] Setup script is running in tmux session '$TMUX_SESSION' on the remote machine."
echo "[INFO] You can safely close this terminal. To check progress:"
echo "         ssh $REMOTE 'tmux attach -t $TMUX_SESSION'     # attach to the session"
echo "         ssh $REMOTE 'tail -f $REMOTE_LOG'              # follow the log"
echo ""
echo "[INFO] Waiting for setup script to finish (polling log for completion)..."

SETUP_WAIT=0
SETUP_MAX=7200  # 2 hours max
while [[ $SETUP_WAIT -lt $SETUP_MAX ]]; do
    # Check if tmux session is still alive
    if ! $SSH_CMD $REMOTE "tmux has-session -t '$TMUX_SESSION' 2>/dev/null"; then
        echo "[INFO] Setup script finished (tmux session ended) after $((SETUP_WAIT))s"
        break
    fi
    # Print a status line every 60 seconds
    if (( SETUP_WAIT % 60 == 0 && SETUP_WAIT > 0 )); then
        echo "[INFO] Setup still running... ($((SETUP_WAIT / 60))m elapsed)"
    fi
    sleep 15
    SETUP_WAIT=$((SETUP_WAIT + 15))
done

if [[ $SETUP_WAIT -ge $SETUP_MAX ]]; then
    echo "[WARN] Setup script still running after $((SETUP_MAX / 60))m. It will continue in the tmux session."
    echo "[WARN] Check progress with: ssh $REMOTE 'tmux attach -t $TMUX_SESSION'"
fi

# Copy log file back for debugging
LOCAL_LOG="./logs/deploy-$(date +%Y%m%d-%H%M%S)-$(basename "$MACHINE_HOST").log"
mkdir -p ./logs
echo "[INFO] Copying remote log $REMOTE_LOG to $LOCAL_LOG"
eval $RSYNC_CMD "$REMOTE:$REMOTE_LOG" "$LOCAL_LOG"

# Add machine to jobserver
echo "[INFO] Adding machine to jobserver: $J_BIN machine add $MACHINE $CLASS"
"$J_BIN" machine add "$MACHINE" "$CLASS"

echo "[INFO] Setup complete. Log saved to $LOCAL_LOG"
