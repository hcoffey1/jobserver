#!/bin/bash
# Start the job server. Run it inside tmux yourself.
# Pass --allow_snap_fail on a fresh head node only; it discards job history.
set -eu
cd "$(dirname "$0")/.."
exec ./target/debug/expjobserver ./expjobserver_remote_wrapper.sh ./logs/ ./example.log.yml "$@"
