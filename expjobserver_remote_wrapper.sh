#!/bin/bash

# expjobserver Remote Wrapper Script
# This script allows expjobserver to run commands on remote machines via SSH
#
# Usage: This script is passed as the RUNNER argument to expjobserver
# Example: expjobserver ./expjobserver_remote_wrapper.sh /path/to/logs/ /path/to/log.yml
source example_config.sh

set -euo pipefail

# Configuration
DEFAULT_SSH_USER="${EXPJOBSERVER_SSH_USER:-$(whoami)}"
DEFAULT_SSH_OPTIONS="${EXPJOBSERVER_SSH_OPTIONS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR}"
DEFAULT_REMOTE_WORKDIR="${EXPJOBSERVER_REMOTE_WORKDIR:-/tmp/expjobserver}"
RESULTS_DIR_NAME="results"

# Function to print usage
usage() {
    cat << EOF
expjobserver Remote Wrapper Script

This script is designed to be used as the RUNNER for expjobserver to execute
commands on remote machines via SSH.

Environment Variables:
  EXPJOBSERVER_SSH_USER     - SSH username (default: current user)
  EXPJOBSERVER_SSH_OPTIONS  - SSH options (default: -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
  EXPJOBSERVER_REMOTE_WORKDIR - Remote working directory (default: /tmp/expjobserver)

The wrapper expects to be called by expjobserver with:
  $0 --print_results_path <machine> <command> [args...]

Where <machine> should be in format: hostname:port or just hostname
EOF
}

# Function to extract hostname and port from machine string
parse_machine() {
    local machine="$1"
    if [[ "$machine" == *":"* ]]; then
        MACHINE_HOST="${machine%:*}"
        MACHINE_PORT="${machine#*:}"
    else
        MACHINE_HOST="$machine"
        MACHINE_PORT="22"
    fi
}

# Function to generate a unique job ID based on arguments
generate_job_id() {
    echo "job_$(date +%s)_$$_$(echo "$*" | md5sum | cut -d' ' -f1 | head -c8)"
}

# Function to check if a command is a script file
is_script_file() {
    local cmd="$1"
    # Check if it's a path to a file (contains . or /)
    if [[ "$cmd" == *"/"* ]] || [[ "$cmd" == *"."* ]]; then
        # Remove any leading ./ 
        local clean_path="${cmd#./}"
        # Check if file exists locally
        if [[ -f "$clean_path" ]]; then
            return 0
        fi
    fi
    return 1
}

# Function to upload and execute a script file
upload_and_execute_script() {
    local machine="$1"
    local job_id="$2"
    local script_path="$3"
    shift 3
    local script_args="$*"
    
    parse_machine "$machine"
    
    local ssh_cmd="ssh"
    if [[ "$MACHINE_PORT" != "22" ]]; then
        ssh_cmd="$ssh_cmd -p $MACHINE_PORT"
    fi
    ssh_cmd="$ssh_cmd $DEFAULT_SSH_OPTIONS $DEFAULT_SSH_USER@$MACHINE_HOST"
    
    local remote_job_dir="$DEFAULT_REMOTE_WORKDIR/$job_id"
    local remote_results_dir="$remote_job_dir/$RESULTS_DIR_NAME"
    local script_name=$(basename "$script_path")
    local remote_script_path="$remote_job_dir/$script_name"
    
    echo "=== Uploading and executing script: $script_path ===" >&2
    
    # Create remote working directory and results directory
    $ssh_cmd "mkdir -p '$remote_results_dir'"
    
    # Upload the script file
    local scp_cmd="scp"
    if [[ "$MACHINE_PORT" != "22" ]]; then
        scp_cmd="$scp_cmd -P $MACHINE_PORT"
    fi
    scp_cmd="$scp_cmd $DEFAULT_SSH_OPTIONS"
    
    echo "Uploading script $script_path to $remote_script_path" >&2
    $scp_cmd "$script_path" "$DEFAULT_SSH_USER@$MACHINE_HOST:$remote_script_path"
    
    # Make script executable and run it
    $ssh_cmd "chmod +x '$remote_script_path' && cd '$remote_job_dir' && '$remote_script_path' $script_args"
}

# Function to execute command on remote machine
execute_remote_command() {
    local machine="$1"
    local job_id="$2"
    shift 2
    local command="$*"
    
    parse_machine "$machine"
    
    local ssh_cmd="ssh"
    if [[ "$MACHINE_PORT" != "22" ]]; then
        ssh_cmd="$ssh_cmd -p $MACHINE_PORT"
    fi
    ssh_cmd="$ssh_cmd $DEFAULT_SSH_OPTIONS $DEFAULT_SSH_USER@$MACHINE_HOST"
    
    local remote_job_dir="$DEFAULT_REMOTE_WORKDIR/$job_id"
    local remote_results_dir="$remote_job_dir/$RESULTS_DIR_NAME"
    
    # Create remote working directory and results directory
    $ssh_cmd "mkdir -p '$remote_results_dir'"
    
    # Create a script to run on the remote machine
    local remote_script=$(cat << 'REMOTE_SCRIPT'
#!/bin/bash
set -euo pipefail

JOB_DIR="$1"
RESULTS_DIR="$JOB_DIR/results"
shift

# Change to job directory
cd "$JOB_DIR"

# Run the actual command
echo "=== Running command: $* ==="
echo "=== Working directory: $(pwd) ==="
echo "=== Results directory: $RESULTS_DIR ==="

# Execute the command and capture exit code
set +e
"$@"
EXIT_CODE=$?
set -e

# If the command succeeded and created any files, report the results directory
if [[ $EXIT_CODE -eq 0 ]]; then
    # Check if there are any files in the results directory
    if [[ -n "$(find "$RESULTS_DIR" -type f 2>/dev/null | head -n 1)" ]]; then
        echo "RESULTS: $RESULTS_DIR"
    else
        # If no files in results dir, check if command created any files in current dir
        if [[ -n "$(find . -maxdepth 1 -type f -newer "$RESULTS_DIR" 2>/dev/null | head -n 1)" ]]; then
            # Move any newly created files to results directory
            find . -maxdepth 1 -type f -newer "$RESULTS_DIR" -exec mv {} "$RESULTS_DIR/" \;
            echo "RESULTS: $RESULTS_DIR"
        fi
    fi
fi

exit $EXIT_CODE
REMOTE_SCRIPT
)
    
    # Send the script to remote machine and execute it
    echo "$remote_script" | $ssh_cmd "cat > '$remote_job_dir/run_job.sh' && chmod +x '$remote_job_dir/run_job.sh'"
    
    # Execute the job script on remote machine
    $ssh_cmd "'$remote_job_dir/run_job.sh' '$remote_job_dir' $command"
    
    # Clean up (optional - comment out if you want to keep job directories for debugging)
    # $ssh_cmd "rm -rf '$remote_job_dir'"
}

# Main script logic
main() {
    # Check if --print_results_path flag is present (required by expjobserver)
    if [[ "${1:-}" != "--print_results_path" ]]; then
        echo "Error: This script must be called with --print_results_path flag" >&2
        echo "This script is designed to be used as the RUNNER for expjobserver" >&2
        usage >&2
        exit 1
    fi
    
    shift  # Remove --print_results_path flag
    
    # Check if we have at least machine and command
    if [[ $# -lt 2 ]]; then
        echo "Error: Missing required arguments" >&2
        echo "Usage: $0 --print_results_path <machine> <command> [args...]" >&2
        exit 1
    fi
    
    local machine="$1"
    shift
    local command="$*"
    
    # Generate unique job ID
    local job_id=$(generate_job_id "$machine" "$command")
    
    echo "=== Expjobserver Remote Wrapper ===" >&2
    echo "Machine: $machine" >&2
    echo "Job ID: $job_id" >&2
    echo "Command: $command" >&2
    echo "======================================" >&2
    
    # Parse the command to check if first argument is a script file
    local first_arg=$(echo "$command" | awk '{print $1}')
    local remaining_args=$(echo "$command" | cut -d' ' -f2- 2>/dev/null || echo "")
    
    # Check if the first argument is a script file
    if is_script_file "$first_arg"; then
        echo "Detected script file: $first_arg" >&2
        upload_and_execute_script "$machine" "$job_id" "$first_arg" $remaining_args
    else
        echo "Executing command directly" >&2
        execute_remote_command "$machine" "$job_id" $command
    fi
}

# Handle help flag
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

# Run main function with all arguments
main "$@"
