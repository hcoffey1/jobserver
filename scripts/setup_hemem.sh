echo "=== Setting up experiment environment ==="
cd $HOME

# Create 
rsync -azh --info=progress2 /deploy/add_machine/deploy/ $HOME

set +e 
echo "Changing into workloads"
pushd workloads
./setup.sh
popd
set -e

echo "Changing into tiering_solutions"
cd tiering_solutions

# Will reboot the machine
sudo ./scripts/setup.sh
