#!/bin/bash
# One-shot root partition & filesystem expansion with automatic post-boot completion.
# - Detects root partition/device and filesystem
# - Disables swap and comments swap entries in /etc/fstab
# - Removes trailing partitions after root (e.g., old swap partition)
# - Expands root to end-of-disk (sfdisk)
# - Fixes GPT backup header (sgdisk -e) if GPT
# - Grows filesystem (resize2fs for ext2/3/4; xfs_growfs for XFS)
# - Creates swapfile and enables it
# - If kernel can't re-read the new table while root is mounted, installs
#   a temporary systemd unit to finish on next boot, then reboots automatically.
set -euo pipefail

# ---------- Config ----------
SWAPFILE_SIZE="${SWAPFILE_SIZE:-8G}"
AUTO_REBOOT="${AUTO_REBOOT:-1}"         # 1 = auto reboot if kernel can't re-read partition table
LOGTAG="rootfs-resizer"
STATE_DIR="/var/lib/rootfs-resizer"
POST_SCRIPT="/usr/local/sbin/rootfs-resize-postboot.sh"
POST_UNIT="/etc/systemd/system/rootfs-resize-postboot.service"
MARKER_PENDING="$STATE_DIR/pending"
MARKER_DONE="$STATE_DIR/done"

# ---------- Ensure Bash + sudo ----------
if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "[$LOGTAG][ERROR] This script must run under bash." >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

# ---------- Helpers ----------
log() { echo "[$LOGTAG] $*"; }
err() { echo "[$LOGTAG][ERROR] $*" >&2; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }; }

# ---------- Preflight ----------
require_cmd lsblk
require_cmd sfdisk
require_cmd partprobe
require_cmd sed
require_cmd awk
require_cmd grep
require_cmd tee
mkdir -p "$STATE_DIR"

# ---------- Detect root partition & device ----------
read -r root_line < <(lsblk -P -o NAME,PKNAME,FSTYPE,MOUNTPOINT | grep 'MOUNTPOINT="/"')
[[ -n "${root_line:-}" ]] || { err "Could not detect root mountpoint via lsblk"; exit 1; }
# Example: NAME="sda3" PKNAME="sda" FSTYPE="ext3" MOUNTPOINT="/"
eval "$root_line"
root_part="${NAME}"
root_device="${PKNAME}"
fs_type="${FSTYPE:-}"

log "Root partition : $root_part"
log "Root device    : $root_device"
log "Root filesystem: ${fs_type:-unknown}"

[[ -b "/dev/$root_device" ]] || { err "/dev/$root_device not found"; exit 1; }
[[ -b "/dev/$root_part"   ]] || { err "/dev/$root_part not found"; exit 1; }

# Partition number (supports sda3, nvme0n1p3, etc.)
if [[ "$root_part" =~ ([0-9]+)$ ]]; then
  root_part_num="${BASH_REMATCH[1]}"
else
  err "Unable to extract partition number from $root_part"
  exit 1
fi

# ---------- Disable swap & comment fstab lines ----------
log "Disabling all swap temporarily..."
swapoff -a || true

if [[ -f /etc/fstab ]]; then
  if ! grep -q "$LOGTAG" /etc/fstab; then
    log "Backing up /etc/fstab and commenting swap lines."
    cp /etc/fstab /etc/fstab.bak
    sed -i -E 's/^([^#].*[[:space:]]swap[[:space:]].*)/# '"$LOGTAG"' disabled: \1/' /etc/fstab
  else
    log "Swap lines in /etc/fstab already processed earlier."
  fi
fi

# ---------- Partition table: read & compute desired size ----------
log "Reading current partition table..."
sfdisk -d "/dev/$root_device" > /tmp/sfdisk.old
cp /tmp/sfdisk.old /tmp/sfdisk.new

declare -A starts sizes
while read -r line; do
  name="$(awk '{print $1}' <<< "$line")"
  start="$(sed -n -E 's/.*start= *([0-9]+).*/\1/p' <<< "$line")"
  size="$(sed -n -E 's/.*size= *([0-9]+).*/\1/p' <<< "$line")"
  [[ -n "$name" && -n "$start" && -n "$size" ]] || continue
  name="${name#/dev/}"
  starts["$name"]="$start"
  sizes["$name"]="$size"
done < <(grep '^/dev' /tmp/sfdisk.new)

root_start="${starts[$root_part]}"
[[ -n "${root_start:-}" ]] || { err "Could not determine root start sector"; exit 1; }

last_end=0
trailing_parts=()
for name in "${!starts[@]}"; do
  end=$(( starts["$name"] + sizes["$name"] ))
  (( end > last_end )) && last_end=$end
  if (( starts["$name"] > root_start )); then
    trailing_parts+=("$name")
  fi
done

current_root_size="${sizes[$root_part]}"
desired_root_size=$(( last_end - root_start ))

log "Current root size (sectors): $current_root_size"
log "Desired  root size (sectors): $desired_root_size"

# ---------- Remove trailing partitions if any ----------
if ((${#trailing_parts[@]} > 0)); then
  log "Found trailing partitions after root: ${trailing_parts[*]}"
  for name in "${trailing_parts[@]}"; do
    log "Removing partition $name from working table..."
    sed -i "/\/dev\/$name/d" /tmp/sfdisk.new
  done
else
  log "No trailing partitions after root."
fi

# ---------- Expand root to end-of-disk ----------
if (( current_root_size >= desired_root_size )); then
  log "Root partition already consumes available space."
else
  log "Updating root partition size in working table..."
  sed -E "s#(.*$root_part.*size= *)[0-9]+(.*)#\1$desired_root_size\2#" \
    /tmp/sfdisk.new > /tmp/sfdisk.new.tmp
  mv /tmp/sfdisk.new.tmp /tmp/sfdisk.new

  if ! diff -q /tmp/sfdisk.old /tmp/sfdisk.new >/dev/null; then
    log "Applying updated partition table (sfdisk --no-reread --force)..."
    sfdisk --no-reread --force "/dev/$root_device" < /tmp/sfdisk.new || true
  else
    log "Partition table unchanged; skipping write."
  fi
fi

# ---------- Fix GPT backup header if applicable ----------
if sgdisk -p "/dev/$root_device" >/dev/null 2>&1; then
  log "Detected GPT; fixing backup header (sgdisk -e)..."
  sgdisk -e "/dev/$root_device" || log "sgdisk -e failed; continuing."
fi

# ---------- Ask kernel to re-read table ----------
log "Requesting kernel to re-read partition table (partprobe)..."
partprobe "/dev/$root_device" || log "partprobe reported busy (expected with mounted root)."

# Compare partition size before/after in BYTES to decide online vs post-boot
bytes_before="$(lsblk -b -n -o SIZE "/dev/$root_part")"
sleep 1
bytes_after="$(lsblk -b -n -o SIZE "/dev/$root_part")"
needs_reboot=0
if [[ "$bytes_after" -gt "$bytes_before" ]]; then
  log "Kernel reports new root partition size: $bytes_after bytes (was $bytes_before)."
else
  log "Kernel still reports old size; will complete after reboot."
  needs_reboot=1
fi

# ---------- FS grow + swapfile (online if possible) ----------
grow_fs_and_swap() {
  local fs="$1"
  if [[ "$fs" =~ ^ext(2|3|4)$ ]]; then
    require_cmd resize2fs
    log "Growing ext filesystem with resize2fs..."
    resize2fs "/dev/$root_part"
  elif [[ "$fs" == "xfs" ]]; then
    require_cmd xfs_growfs
    log "Growing XFS (mounted at /) with xfs_growfs..."
    xfs_growfs /
  else
    err "Unsupported/unknown filesystem '$fs'—manual resize required."
    exit 1
  fi

  # Configure swapfile
  if ! grep -qE '^[^#].*\s+/swapfile\s+none\s+swap\s' /etc/fstab; then
    log "Creating swapfile (${SWAPFILE_SIZE}) and enabling it..."
    fallocate -l "$SWAPFILE_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
  else
    log "Swapfile already present in /etc/fstab."
  fi
  swapon -a || true
}

if [[ "$needs_reboot" -eq 0 ]]; then
  grow_fs_and_swap "${fs_type:-}"
  log "Resize completed online. Current state:"
  lsblk
  df -h /
  swapon --show || true
  rm -f "$MARKER_PENDING"
  touch "$MARKER_DONE"
  exit 0
fi

# ---------- Install post-boot finisher & reboot ----------
log "Installing post-boot finisher to complete filesystem growth and swapfile setup after reboot."

# Create post-boot script with SWAPFILE_SIZE baked in
tee "$POST_SCRIPT" >/dev/null <<EOS
#!/bin/bash
set -euo pipefail
LOGTAG="rootfs-resizer"
STATE_DIR="/var/lib/rootfs-resizer"
MARKER_PENDING="\$STATE_DIR/pending"
MARKER_DONE="\$STATE_DIR/done"
SWAPFILE_SIZE="$SWAPFILE_SIZE"

log() { echo "[\$LOGTAG][postboot] \$*"; }
err() { echo "[\$LOGTAG][postboot][ERROR] \$*" >&2; }

# Detect root partition/device/fs
read -r root_line < <(lsblk -P -o NAME,PKNAME,FSTYPE,MOUNTPOINT | grep 'MOUNTPOINT="/"')
eval "\$root_line"
root_part="\$NAME"
fs_type="\$FSTYPE"

log "Post-boot: root=\$root_part fs=\$fs_type"

# Verify kernel partition size and grow FS
if [[ "\$fs_type" =~ ^ext(2|3|4)\$ ]]; then
  command -v resize2fs >/dev/null 2>&1 || { err "resize2fs not found"; exit 1; }
  log "Running resize2fs on /dev/\$root_part..."
  resize2fs "/dev/\$root_part"
elif [[ "\$fs_type" == "xfs" ]]; then
  command -v xfs_growfs >/dev/null 2>&1 || { err "xfs_growfs not found"; exit 1; }
  log "Running xfs_growfs on / ..."
  xfs_growfs /
else
  err "Unsupported FS '\$fs_type'—cannot grow automatically."
  exit 1
fi

# Configure swapfile if missing
if ! grep -qE '^[^#].*\\s+/swapfile\\s+none\\s+swap\\s' /etc/fstab; then
  log "Creating swapfile (\$SWAPFILE_SIZE) and enabling it..."
  fallocate -l "\$SWAPFILE_SIZE" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
else
  log "Swapfile already declared in /etc/fstab."
fi
swapon -a || true

log "Post-boot expansion complete."
lsblk | sed 's/^/[postboot] /'
df -h / | sed 's/^/[postboot] /'
swapon --show || true

rm -f "\$MARKER_PENDING"
touch "\$MARKER_DONE"
EOS
chmod +x "$POST_SCRIPT"

# Create systemd unit (runs once if marker exists)
tee "$POST_UNIT" >/dev/null <<EOS
[Unit]
Description=RootFS Resize Post-Boot Finisher
ConditionPathExists=$MARKER_PENDING
After=local-fs.target

[Service]
Type=oneshot
ExecStart=$POST_SCRIPT

[Install]
WantedBy=multi-user.target
EOS

systemctl daemon-reload
systemctl enable "$(basename "$POST_UNIT")"
touch "$MARKER_PENDING"

log "Everything is staged. System will reboot to apply partition changes and finish automatically."
if [[ "$AUTO_REBOOT" -eq 1 ]]; then
  reboot
else
  err "AUTO_REBOOT=0 set; please reboot manually to let the post-boot finisher complete."
  exit 2
fi

