#!/bin/bash
#
# Default configuration for the expjobserver remote wrapper.
#
# This file is SOURCED by expjobserver_remote_wrapper.sh on every job run, so
# keep it side-effect free (no echo spam — it lands in every job log otherwise).
#
# Every value uses ${VAR:-default}, so anything you export in your shell takes
# precedence. For real/local values you don't want in git (usernames, hosts),
# create config.local.sh (gitignored) — the wrapper sources it after this file,
# so it wins. See the README addendum for details.

# SSH user used to reach the test machines (default: hjcoffey).
export EXPJOBSERVER_SSH_USER="${EXPJOBSERVER_SSH_USER:-hjcoffey}"

# SSH options applied to every connection.
export EXPJOBSERVER_SSH_OPTIONS="${EXPJOBSERVER_SSH_OPTIONS:--o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=30}"

# Per-job working directory created on each remote machine.
export EXPJOBSERVER_REMOTE_WORKDIR="${EXPJOBSERVER_REMOTE_WORKDIR:-/tmp/expjobserver}"
