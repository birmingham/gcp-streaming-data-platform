#!/bin/bash
set -euo pipefail

MOUNT_POINT="${data_mount}"
DATA_DISK="/dev/disk/by-id/google-kafka-data"
KAFKA_DIR="/opt/kafka"

# -----------------------------------------------------------------------
# Format (if needed) and mount the data disk as XFS
# -----------------------------------------------------------------------
if ! blkid "$DATA_DISK" >/dev/null 2>&1; then
  mkfs.xfs "$DATA_DISK"
fi

mkdir -p "$MOUNT_POINT"
if ! grep -qs "$MOUNT_POINT" /proc/mounts; then
  mount "$DATA_DISK" "$MOUNT_POINT"
fi

# Persist across reboots
if ! grep -qs "$DATA_DISK" /etc/fstab; then
  echo "$DATA_DISK $MOUNT_POINT xfs defaults,nofail 0 2" >> /etc/fstab
fi

mkdir -p "$MOUNT_POINT/kraft-logs"

# -----------------------------------------------------------------------
# Install Java and Kafka
# -----------------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y openjdk-17-jre-headless wget

if [ ! -d "$KAFKA_DIR" ]; then
  wget -q "https://archive.apache.org/dist/kafka/${kafka_version}/kafka_${scala_version}-${kafka_version}.tgz" -O /tmp/kafka.tgz
  mkdir -p "$KAFKA_DIR"
  tar -xzf /tmp/kafka.tgz -C "$KAFKA_DIR" --strip-components=1
fi

# -----------------------------------------------------------------------
# Template server.properties
#
# node.id, advertised.listeners, and log.dirs are unique per broker.
# controller.quorum.voters is identical across all three nodes (passed
# in fully-formed from Terraform) so every broker agrees on the full
# controller set before the quorum ever has to form.
# -----------------------------------------------------------------------
mkdir -p "$KAFKA_DIR/config/kraft"
cat > "$KAFKA_DIR/config/kraft/server.properties" <<EOF
node.id=${node_id}
process.roles=broker,controller

listeners=BROKER://0.0.0.0:${broker_port},CONTROLLER://0.0.0.0:${controller_port}
advertised.listeners=BROKER://${advertised_ip}:${broker_port}
controller.listener.names=CONTROLLER
listener.security.protocol.map=BROKER:PLAINTEXT,CONTROLLER:PLAINTEXT
inter.broker.listener.name=BROKER

controller.quorum.voters=${controller_quorum_voters}

log.dirs=$MOUNT_POINT/kraft-logs
num.partitions=3
default.replication.factor=3
min.insync.replicas=2
offsets.topic.replication.factor=3
transaction.state.log.replication.factor=3
transaction.state.log.min.isr=2
EOF

# -----------------------------------------------------------------------
# One-time KRaft storage format
#
# Must run exactly once per node, using the SAME cluster ID on all three
# (generated once by Terraform, not per node). The marker file stops a
# reboot from re-running this and wiping the log directory.
# -----------------------------------------------------------------------
FORMAT_MARKER="$MOUNT_POINT/.kraft-formatted"
if [ ! -f "$FORMAT_MARKER" ]; then
  "$KAFKA_DIR/bin/kafka-storage.sh" format \
    -t "${cluster_id}" \
    -c "$KAFKA_DIR/config/kraft/server.properties"
  touch "$FORMAT_MARKER"
fi

# -----------------------------------------------------------------------
# systemd unit so Kafka comes back up automatically on VM restart
# -----------------------------------------------------------------------
cat > /etc/systemd/system/kafka.service <<EOF
[Unit]
Description=Kafka (KRaft broker+controller - ${node_name})
After=network.target

[Service]
Type=simple
ExecStart=$KAFKA_DIR/bin/kafka-server-start.sh $KAFKA_DIR/config/kraft/server.properties
ExecStop=$KAFKA_DIR/bin/kafka-server-stop.sh
Restart=on-failure
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kafka
systemctl restart kafka
