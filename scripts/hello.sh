#!/usr/bin/env bash
# Tiny sanity-check job: prints a message and leaves a marker file behind.
# Run via: j job add <CLASS> "{MACHINE} ./hello.sh" <CP_PATH>
#
# The wrapper uploads this script and runs it with cwd = the remote job dir,
# which already contains a "results/" subdir. Anything we put in results/ and
# announce with a "RESULTS:" line gets rsynced back to <CP_PATH> on the server.
set -euo pipefail

echo "Hello world"

mkdir -p results
touch results/I_was_here.txt

# Tell the server where to copy results back from (absolute remote path).
echo "RESULTS: $PWD/results/"
