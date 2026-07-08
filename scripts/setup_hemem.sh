#!/bin/bash
echo "=== Setting up experiment environment ==="
cd $HOME

# Ensure required system packages are installed -- jobs fail on the remote if
# these are missing: numactl (workloads pin memory/CPU), cmake (several
# workloads, e.g. faiss/duckdb, build with it).
MISSING_PKGS=()
command -v numactl >/dev/null 2>&1 || MISSING_PKGS+=(numactl)
command -v cmake   >/dev/null 2>&1 || MISSING_PKGS+=(cmake)
if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo "=== Installing: ${MISSING_PKGS[*]} ==="
    sudo apt-get update -y && sudo apt-get install -y "${MISSING_PKGS[@]}"
fi

# Create
rsync -azh --info=progress2 /deploy/add_machine/deploy/ $HOME

# Repair the deployed base conda: the deployed miniconda ships without pip and
# archspec, which breaks EVERY conda solve (both libmamba and classic) with
# "No module named 'archspec'" / "'Index' object has no attribute
# '_system_packages'" -- so conda-backed workloads (e.g. ogb) fail to build.
# Bootstrap pip via ensurepip, then install archspec. Idempotent. Runs before
# the workloads setup below so its conda env creation succeeds.
CONDA_PY="$HOME/miniconda3/bin/python"
if [[ -x "$CONDA_PY" ]]; then
    echo "=== Repairing base conda (pip + archspec) ==="
    "$CONDA_PY" -c "import pip"          2>/dev/null || "$CONDA_PY" -m ensurepip --upgrade
    "$CONDA_PY" -c "import archspec.cpu" 2>/dev/null || "$CONDA_PY" -m pip install archspec
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
