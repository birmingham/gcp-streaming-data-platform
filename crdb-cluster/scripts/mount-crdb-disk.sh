#!/bin/bash
# Run once on each existing node (crdb-lab-node-0 through -4) to format and
# mount its dedicated CockroachDB data disk. Safe to re-run: it checks for
# an existing filesystem before formatting, so it won't wipe data on a
# second pass.
set -euo pipefail

DEVICE="/dev/disk/by-id/google-crdb-data"
MOUNT_POINT="/mnt/disks/crdb-data"

if [ ! -e "$DEVICE" ]; then
  echo "ERROR: $DEVICE not found. Is the crdb-data disk actually attached to this VM?"
  exit 1
fi

if ! sudo blkid "$DEVICE" > /dev/null 2>&1; then
  echo "No filesystem found on $DEVICE — formatting as ext4."
  sudo mkfs.ext4 -F "$DEVICE"
else
  echo "$DEVICE already has a filesystem — skipping format."
fi

sudo mkdir -p "$MOUNT_POINT"

UUID=$(sudo blkid -s UUID -o value "$DEVICE")
if ! grep -q "$UUID" /etc/fstab; then
  echo "UUID=$UUID $MOUNT_POINT ext4 defaults 0 2" | sudo tee -a /etc/fstab > /dev/null
fi

sudo mount -a
sudo chmod 777 "$MOUNT_POINT"

echo "Mounted at $MOUNT_POINT:"
df -h "$MOUNT_POINT"