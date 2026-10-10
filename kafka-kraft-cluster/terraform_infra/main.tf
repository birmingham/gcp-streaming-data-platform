# =============================================================================
# Kafka KRaft cluster — standalone module
#
# Three brokers, each running combined broker+controller KRaft roles (no
# Zookeeper, no dedicated controller nodes). Private IPs only; egress via
# Cloud NAT; admin/SSH access via IAP tunneling. Deliberately kept as its
# own VPC and its own Terraform state, separate from the CockroachDB
# module — the two clusters stay logically independent, with a Python
# feeder service (its own VPC) reading/writing to both.
#
# Networking (VPC, subnet, NAT, firewall rules, peering) lives in
# ./modules/network-kafka — this file owns everything broker-specific.
# =============================================================================

module "network" {
  source = "../../modules/network-kafka"

  region               = var.region
  subnet_cidr          = var.subnet_cidr
  broker_port          = var.broker_port
  controller_port      = var.controller_port
  broker_tag           = var.broker_tag
  client_source_ranges = var.client_source_ranges
  crdb_network_name    = var.crdb_network_name
  feeder_network_name  = var.feeder_network_name
}

# -----------------------------------------------------------------------
# KRaft cluster identity — generated once here and handed to every node,
# so all three format their storage with the same cluster ID instead of
# each generating its own (which would leave them unable to form a quorum).
# -----------------------------------------------------------------------

resource "random_uuid" "kraft_cluster_id" {}

# Static internal IPs, reserved before any instance exists. Matters even
# more here than in the CockroachDB module: these addresses feed directly
# into each broker's advertised.listeners and into the shared
# controller.quorum.voters list, so they need to be known up front.
resource "google_compute_address" "kafka_node_ip" {
  count        = var.node_count
  name         = "kafka-kraft-node-ip-${count.index}"
  address_type = "INTERNAL"
  subnetwork   = module.network.subnetwork_id
  region       = var.region
}

resource "google_compute_disk" "kafka_data" {
  count = var.node_count
  name  = "kafka-kraft-data-${count.index}"
  type  = "pd-ssd"
  zone  = var.zone
  size  = var.data_disk_size_gb
}

resource "google_compute_instance" "kafka_broker" {
  count                     = var.node_count
  name                      = "kafka-kraft-broker-${count.index}"
  machine_type              = var.machine_type
  zone                      = var.zone
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
      type  = "pd-ssd"
    }
  }

  # Separate data disk per broker for Kafka log segments, formatted XFS
  # and mounted at var.data_mount_path by the startup script.
  attached_disk {
    source      = google_compute_disk.kafka_data[count.index].id
    device_name = "kafka-data"
  }

  network_interface {
    subnetwork = module.network.subnetwork_id
    network_ip = google_compute_address.kafka_node_ip[count.index].address
    # no access_config block: brokers are private-only, egress via Cloud NAT
  }

  tags = ["kafka-kraft", var.broker_tag]

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("../templates/kafka-startup.sh.tpl", {
      node_id         = count.index
      node_name       = "kafka-kraft-broker-${count.index}"
      broker_port     = var.broker_port
      controller_port = var.controller_port
      advertised_ip   = google_compute_address.kafka_node_ip[count.index].address
      # Identical on every node: lists all three node IDs paired with
      # their static IPs and the controller port, so every broker knows
      # the full quorum up front.
      controller_quorum_voters = join(",", [
        for i, addr in google_compute_address.kafka_node_ip[*].address :
        "${i}@${addr}:${var.controller_port}"
      ])
      cluster_id    = random_uuid.kraft_cluster_id.result
      data_mount    = var.data_mount_path
      kafka_version = var.kafka_version
      scala_version = var.scala_version
    })
  }

  labels = {
    environment = "client-project"
    project     = "kafka-kraft-cluster"
  }
}
