echo "=== Setting up experiment environment ==="
cd $HOME

# Create 
rsync -azh --info=progress2 /deploy/add_machine/deploy/ $HOME

echo "Changing into tiering_solutions"
cd tiering_solutions

# Will reboot the machine
sudo ./scripts/setup.sh
