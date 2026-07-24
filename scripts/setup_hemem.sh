#!/bin/bash
echo "=== Setting up experiment environment ==="
cd $HOME

# Mount the spare 1 TB /dev/sdb and relocate ~/working onto it BEFORE the deploy
# rsync below populates ~/working -- otherwise the large sweep data lands on the
# ~440 G root and fills it.  Single source of truth on the project share.
MOUNT_SCRATCH="${MOUNT_SCRATCH:-/proj/instrument-PG0/mount_scratch.sh}"
if [[ -r "$MOUNT_SCRATCH" ]]; then
    echo "=== Mounting scratch disk + relocating ~/working (mount_scratch.sh) ==="
    bash "$MOUNT_SCRATCH" || echo "WARNING: mount_scratch.sh reported errors; continuing" >&2
else
    echo "WARNING: mount_scratch.sh not found at $MOUNT_SCRATCH; scratch disk not set up" >&2
fi

# Ensure required system packages are installed -- jobs fail on the remote if
# these are missing: numactl (workloads pin memory/CPU), cmake (several
# workloads, e.g. faiss/duckdb, build with it), msr-tools (onboot.sh uses wrmsr
# for the CXL/bandwidth-emulation MSRs before each sweep runs).
#
# msr-tools is VALIDITY-CRITICAL: without it onboot.sh's wrmsr silently no-ops,
# the slow tier is never throttled, and every result from the host is invalid
# (this once wiped out a whole campaign).  So: check with dpkg (PATH-independent,
# unlike `command -v` which misses /usr/sbin binaries), run update SEPARATELY
# from install (a failed `apt-get update` must NOT skip the install via &&), and
# HARD-VERIFY msr-tools landed -- a missing msr-tools aborts provisioning for
# this host rather than silently shipping an un-emulated node.
sudo apt-get update -y -o DPkg::Lock::Timeout=600 \
    || echo "WARNING: apt-get update failed; attempting installs anyway" >&2
MISSING_PKGS=()
for pkg in numactl cmake msr-tools; do
    dpkg -s "$pkg" >/dev/null 2>&1 || MISSING_PKGS+=("$pkg")
done
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo "=== Installing: ${MISSING_PKGS[*]} ==="
    sudo apt-get install -y -o DPkg::Lock::Timeout=600 "${MISSING_PKGS[@]}" \
        || echo "WARNING: apt-get install returned non-zero" >&2
fi
if ! dpkg -s msr-tools >/dev/null 2>&1 \
        || { [[ ! -x /usr/sbin/wrmsr ]] && ! command -v wrmsr >/dev/null 2>&1; }; then
    echo "============================================================" >&2
    echo "FATAL [$(hostname -s)]: msr-tools is NOT installed." >&2
    echo "  onboot.sh's bandwidth-emulation wrmsr would silently no-op and" >&2
    echo "  results would be INVALID.  Aborting provisioning for this host." >&2
    echo "============================================================" >&2
    exit 1
fi
echo "=== msr-tools verified (wrmsr present) on $(hostname -s) ==="

# Unpack the deploy into ~/working, NOT $HOME.  The deploy root shipped by
# add_machine.sh IS ~/working (regent + workloads), so it must land one level
# down or every remote path breaks: jobs reference ~/working/regent and
# $HOME/working/workloads, and the `pushd working/workloads` below expects it.
# mount_scratch.sh (above) has already made ~/working a symlink onto the 1 TB
# scratch disk, so this writes through to /dev/sdb rather than filling root.
mkdir -p "$HOME/working"
rsync -azh --info=progress2 /deploy/add_machine/deploy/ "$HOME/working/"

# Ensure a working base conda + dataVis env via the cluster's single source of
# truth (the deployed miniconda ships without pip/archspec, which breaks EVERY
# solve -- ensure_conda.sh repairs that, then builds+verifies dataVis).  Runs
# before the workloads setup below so conda-backed builds (e.g. ogb) succeed.
ENSURE_CONDA="${ENSURE_CONDA:-/proj/instrument-PG0/ensure_conda.sh}"
if [[ -r "$ENSURE_CONDA" ]]; then
    echo "=== Ensuring base conda + dataVis (ensure_conda.sh) ==="
    bash "$ENSURE_CONDA" || echo "WARNING: ensure_conda.sh reported errors; continuing" >&2
else
    echo "WARNING: ensure_conda.sh not found at $ENSURE_CONDA; skipping conda repair" >&2
fi

set +e
echo "Changing into workloads"
pushd working/workloads
./setup.sh
popd
set -e

#echo "Changing into tiering_solutions"
#cd tiering_solutions

# Will reboot the machine
#sudo ./scripts/setup.sh
