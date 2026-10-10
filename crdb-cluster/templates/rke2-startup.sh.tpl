#!/bin/bash
# Rendered per-node by Terraform's templatefile() — do not edit the deployed
# copy on a VM directly; change the .tpl and re-apply instead.
# Vars: token, server_url, node_name, node_index, tls_sans (list), rke2_version
set -euxo pipefail

exec > >(tee /var/log/rke2-startup.log) 2>&1
echo "=== RKE2 node startup (${node_name}): $(date) ==="

# --- Disable swap (required by RKE2/Kubernetes) ---
swapoff -a
sed -i '/\sswap\s/s/^/#/' /etc/fstab

# --- Kernel modules & sysctl required by RKE2 ---
cat <<MODULES > /etc/modules-load.d/rke2.conf
overlay
br_netfilter
MODULES
modprobe overlay
modprobe br_netfilter

cat <<SYSCTL > /etc/sysctl.d/99-rke2.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SYSCTL
sysctl --system

# --- Format (if needed) and mount the dedicated CockroachDB data disk.
#     GCE re-runs startup-script on every boot, not just the first one, so
#     this must never reformat a disk that already has a filesystem.
#     Also wait for the device to actually appear first — startup-script
#     can run before udev finishes creating the by-id symlink for an
#     attached (non-boot) disk, especially under load with several VMs
#     attaching larger disks at once. ---
CRDB_DEVICE="/dev/disk/by-id/google-crdb-data"
CRDB_MOUNT="/mnt/disks/crdb-data"

for i in $(seq 1 30); do
  [ -e "$CRDB_DEVICE" ] && break
  echo "Waiting for $CRDB_DEVICE to appear (attempt $i/30)..."
  sleep 2
done

if [ -e "$CRDB_DEVICE" ]; then
  if ! blkid "$CRDB_DEVICE" > /dev/null 2>&1; then
    mkfs.ext4 -F "$CRDB_DEVICE"
  fi
  mkdir -p "$CRDB_MOUNT"
  CRDB_UUID=$(blkid -s UUID -o value "$CRDB_DEVICE")
  if ! grep -q "$CRDB_UUID" /etc/fstab; then
    echo "UUID=$CRDB_UUID $CRDB_MOUNT ext4 defaults 0 2" >> /etc/fstab
  fi
  mount -a
  chmod 777 "$CRDB_MOUNT"
else
  echo "ERROR: $CRDB_DEVICE never appeared after 60s — data disk not mounted."
fi

# --- If joining an existing cluster, wait for the bootstrap node to be
#     reachable before starting rke2-server. Instances can boot in parallel,
#     so there's no guarantee node 0 is ready first without this. ---
%{ if server_url != "" }
echo "Waiting for bootstrap server at ${server_url} to accept connections..."
until curl -sk --max-time 5 "${server_url}/cacerts" > /dev/null 2>&1; do
  echo "  ...not ready yet, retrying in 10s"
  sleep 10
done
echo "Bootstrap server is reachable."

# Small stagger so joining nodes don't all hit etcd membership at once
sleep $(( ${node_index} * 20 ))
%{ endif }

# --- RKE2 config ---
mkdir -p /etc/rancher/rke2
cat <<CONFIG > /etc/rancher/rke2/config.yaml
token: "${token}"
%{ if server_url != "" }
server: "${server_url}"
%{ endif }
tls-san:
%{ for san in tls_sans }
  - "${san}"
%{ endfor }
write-kubeconfig-mode: "0640"
CONFIG

# --- Install RKE2 server (pinned version — the 'stable' channel has a
#     known intermittent bug where it resolves to a release before its
#     assets are fully uploaded, causing a 404 mid-install) ---
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="${rke2_version}" INSTALL_RKE2_TYPE="server" sh -

# --- Override Canal's pod-to-pod MTU for GCP's real 1460 host MTU (default
#     assumes a standard 1500-byte network). RKE2's embedded controller
#     auto-applies any manifest dropped in this directory once the service
#     starts. 1460 (GCP host MTU) - 50 (VXLAN overhead) = 1410. ---
mkdir -p /var/lib/rancher/rke2/server/manifests
cat <<CANALMTU > /var/lib/rancher/rke2/server/manifests/rke2-canal-config.yaml
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: rke2-canal
  namespace: kube-system
spec:
  valuesContent: |-
    calico:
      vethuMTU: "1410"
CANALMTU

systemctl enable rke2-server.service
systemctl start rke2-server.service

# Convenience: kubectl on PATH once binaries land. Not exporting KUBECONFIG
# globally here — /etc/rancher/rke2/rke2.yaml is root-only (0640), so a
# global export just breaks kubectl for any non-root login. Each user should
# copy it to their own ~/.kube/config instead, which kubectl finds by default.
ln -sf /var/lib/rancher/rke2/bin/kubectl /usr/local/bin/kubectl || true
echo 'export PATH=$PATH:/var/lib/rancher/rke2/bin' > /etc/profile.d/rke2.sh

echo "=== RKE2 node startup complete (${node_name}): $(date) ==="
