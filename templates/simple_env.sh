#!/bin/bash

# Simple environment setup script
set -euo pipefail

echo "=== Simple Environment Setup Started ==="
echo "User: $(whoami)"
echo "Home: $HOME"
echo "Working directory: $(pwd)"

# Create the required directory
echo "Creating ~/hello_there directory..."
mkdir -p ~/hello_there

# Add some content to verify it worked
echo "Setup completed at $(date)" > ~/hello_there/setup_complete.txt
echo "Machine: $(hostname)" >> ~/hello_there/setup_complete.txt

# Verify the directory was created
if [ -d ~/hello_there ]; then
    echo "✓ Successfully created ~/hello_there"
    echo "Contents:"
    ls -la ~/hello_there
else
    echo "✗ Failed to create ~/hello_there"
    exit 1
fi

echo "=== Simple Environment Setup Complete ==="