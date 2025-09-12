#!/usr/bin/env bash
set -xeuo pipefail

# Bash Implementation of LibSCAIL "resize_root_partition".
# This resizes the root partition to fill all available space.
resize_root_partition() {
    # Check if running as root or with sudo access
    if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
        echo "Error: This script requires root privileges or passwordless sudo access"
        exit 1
    fi

    # Find root partition and its device
    eval $(lsblk -P -o NAME,PKNAME,MOUNTPOINT | grep 'MOUNTPOINT="/"')
    local root_part="$NAME"
    local root_device="$PKNAME"

    echo "Root partition: $root_part"
    echo "Root device: $root_device"

    # Verify the root device exists
    if [[ ! -b "/dev/$root_device" ]]; then
        echo "Error: Root device /dev/$root_device not found"
        exit 1
    fi

    # Dump current partition table
    sudo sfdisk -d /dev/"$root_device" > /tmp/sfdisk.old
    cp /tmp/sfdisk.old /tmp/sfdisk.new

    # Turn off swap partitions on this device, if any
    local swaps
    swaps=$(lsblk -l | awk -v dev="$root_device" '$3 == "SWAP" && $2 == dev {print $1}' || true)
    for part in $swaps; do
        echo "Disabling swap on /dev/$part"
        sudo swapoff /dev/"$part" || true
    done

    # Parse partition table into (name, start, size)
    declare -A starts
    declare -A sizes
    while read -r name start size; do
        starts[$name]="$start"
        sizes[$name]="$size"
    done < <(
        grep '^/dev' /tmp/sfdisk.new \
        | sed -E 's|/dev/([a-z0-9]+).*start= *([0-9]+).*size= *([0-9]+).*|\1 \2 \3|'
    )

    local root_start="${starts[$root_part]}"

    # Find last partition by end offset
    local last_end=0
    for name in "${!starts[@]}"; do
        local start=${starts[$name]}
        local size=${sizes[$name]}
        local end=$((start + size))
        if (( end > last_end )); then
            last_end=$end
        fi
    done

    local current_root_size="${sizes[$root_part]}"
    local desired_root_size=$(( last_end - root_start ))

    # If root is already max size, nothing to do
    if (( current_root_size >= desired_root_size )); then
        echo "Root partition already consumes available space, nothing to do."
        return 0
    fi

    # Remove any partitions after root
    local changed=false
    for name in "${!starts[@]}"; do
        if (( ${starts[$name]} > root_start )); then
            echo "Removing partition $name from table"
            sed -i "/$name/d" /tmp/sfdisk.new
            changed=true
        fi
    done

    # Update root partition size
    sed -E "s|(.*$root_part.*size= *)[0-9]+(.*)|\1$desired_root_size\2|" \
        /tmp/sfdisk.new > /tmp/sfdisk.new1
    mv /tmp/sfdisk.new1 /tmp/sfdisk.new

    # Only apply if different from old
    if ! diff -q /tmp/sfdisk.old /tmp/sfdisk.new >/dev/null; then
        echo "Applying updated partition table..."
        sudo sfdisk --force /dev/"$root_device" < /tmp/sfdisk.new || true

        # Inform kernel of partition table changes
        echo "Informing kernel of partition changes..."
        sudo partprobe /dev/"$root_device" || {
            echo "Warning: partprobe failed - this is expected when filesystem is in use"
        }
        
        # Wait a moment for kernel to process changes
        sleep 2
        
        # Check if we're using GPT and fix it to use all available space
        if sudo sgdisk -p /dev/"$root_device" >/dev/null 2>&1; then
            echo "Detected GPT partition table, expanding to use full disk..."
            sudo sgdisk -e /dev/"$root_device" || {
                echo "Warning: sgdisk -e failed, continuing without GPT expansion"
            }
        fi

        echo "Partition table updated. Filesystem resize will happen after reboot."
        echo "Current partition table:"
        sudo fdisk -l /dev/"$root_device" || true
        
        echo "Rebooting to apply partition changes and resize filesystem..."
        sudo reboot
    else
        echo "Partition table already up to date."
    fi

    # Show final state
    lsblk
    df -h
}

# Resize the root partition
resize_root_partition