#!/bin/bash


# Machine Setup Helper for Expjobserver
# Usage: add_machine.sh <machine> <class> <script> [-d <deploy_dir>]

set -euo pipefail

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
    
    # Execute resize script (this will reboot the machine)
    echo "[INFO] Executing resize script on remote machine (this will reboot the machine)"
    $SSH_CMD $REMOTE "chmod +x '$REMOTE_RESIZE_SCRIPT' && '$REMOTE_RESIZE_SCRIPT'" || {
        echo "[INFO] SSH connection lost - this is expected as the machine reboots"
        # Wait for machine to reboot and come back online
        echo "[INFO] Waiting for machine to reboot and come back online..."
        sleep 30  # Initial wait for reboot to start
    
        # Wait for SSH to be available again
        MAX_WAIT=300  # 5 minutes max wait
        WAIT_COUNT=0
        while [[ $WAIT_COUNT -lt $MAX_WAIT ]]; do
            if $SSH_CMD $REMOTE "echo 'Machine is back online'" 2>/dev/null; then
                echo "[INFO] Machine is back online after $((WAIT_COUNT)) seconds"
                break
            fi
            echo "[INFO] Waiting for machine to come back online... ($((WAIT_COUNT))s)"
            sleep 10
            WAIT_COUNT=$((WAIT_COUNT + 10))
        done
        
        if [[ $WAIT_COUNT -ge $MAX_WAIT ]]; then
            echo "[ERROR] Machine did not come back online within $MAX_WAIT seconds"
            exit 1
        fi
        
        # Verify partition resize and handle filesystem resize
        echo "[INFO] Verifying partition resize and performing filesystem resize"
        $SSH_CMD $REMOTE "
            echo '=== Post-reboot partition and filesystem resize ==='
            echo 'Current partition table:'
            sudo fdisk -l 2>/dev/null | grep -A 20 'Disk /dev/sd' | head -30
            echo
            echo 'Current filesystem size:'
            df -h /
            echo
            
            # Find root partition and detect filesystem type
            root_part=\$(lsblk -P -o NAME,MOUNTPOINT | grep 'MOUNTPOINT=\"/\"' | sed 's/.*NAME=\"\([^\"]*\)\".*/\1/')
            fstype=\$(lsblk -f /dev/\"\$root_part\" -o FSTYPE --noheadings | tr -d ' ')
            
            echo \"Root partition: \$root_part\"
            echo \"Filesystem type: \$fstype\"
            echo
            
            # Resize filesystem based on type
            case \"\$fstype\" in
                ext2|ext3|ext4)
                    echo 'Performing ext filesystem resize...'
                    # Check filesystem first
                    sudo e2fsck -f /dev/\"\$root_part\" || {
                        echo 'Warning: filesystem check had issues, continuing with resize...'
                    }
                    # Resize filesystem
                    sudo resize2fs /dev/\"\$root_part\" || {
                        echo 'Error: resize2fs failed'
                        exit 1
                    }
                    ;;
                xfs)
                    echo 'Performing XFS online resize...'
                    sudo xfs_growfs / || {
                        echo 'Error: XFS resize failed'
                        exit 1
                    }
                    ;;
                *)
                    echo \"Warning: Unknown filesystem type '\$fstype', cannot resize\"
                    exit 1
                    ;;
            esac
            
            echo
            echo '=== Final filesystem size after resize ==='
            df -h /
            echo
            echo '=== Partition and filesystem resize complete ==='
        "
        
        echo "[INFO] Partition and filesystem resize completed successfully"
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

# Run the setup script and log output
echo "[INFO] Running setup script on remote and logging to $REMOTE_LOG"
$SSH_CMD $REMOTE "chmod +x '$REMOTE_SCRIPT' && cd '$REMOTE_BASE' && '$REMOTE_SCRIPT' > '$REMOTE_LOG' 2>&1"

# Copy log file back for debugging
LOCAL_LOG="./logs/deploy-$(date +%Y%m%d-%H%M%S)-$(basename "$MACHINE_HOST").log"
mkdir -p ./logs
echo "[INFO] Copying remote log $REMOTE_LOG to $LOCAL_LOG"
eval $RSYNC_CMD "$REMOTE:$REMOTE_LOG" "$LOCAL_LOG"

# Add machine to jobserver
echo "[INFO] Adding machine to jobserver: j machine add $MACHINE $CLASS"
#j machine add "$MACHINE" "$CLASS"

echo "[INFO] Setup complete. Log saved to $LOCAL_LOG"
