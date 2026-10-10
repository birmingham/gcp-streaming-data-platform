# =============================================================================
# Kafka network module
#
# Owns the VPC, subnet, Cloud NAT, and (optional) VPC peering for the
# Kafka KRaft cluster. Firewall rules live in ./firewall.tf. Broker-
# specific resources (static IPs, disks, instances) stay in the root
# module and consume this module's outputs.
# =============================================================================

variable "region" {
  description = "GCP region for the subnet, router, and Cloud NAT"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR range for the Kafka VPC's subnet"
  type        = string
  default     = "10.30.0.0/24"
}

variable "broker_port" {
  description = "TCP port brokers use for client/broker traffic"
  type        = number
}

variable "controller_port" {
  description = "TCP port brokers use for KRaft controller quorum traffic"
  type        = number
}

variable "broker_tag" {
  description = "Network tag applied to broker instances; firewall rules are scoped to this tag rather than a CIDR range"
  type        = string
  default     = "kafka-broker"
}

variable "client_source_ranges" {
  description = "CIDR ranges allowed to reach the broker port for external Kafka client traffic (e.g. the Python feeder's subnet). Left empty until that network's range is known."
  type        = list(string)
  default     = []
}

variable "crdb_network_name" {
  description = "Name of the existing CockroachDB VPC (e.g. \"crdb-lab-network\") to look up via data source and peer with. Current design keeps Kafka and CockroachDB logically separate (no direct peering) — leave as empty string unless that changes."
  type        = string
  default     = ""
}

variable "feeder_network_name" {
  description = "Name of the Python feeder service's VPC to look up via data source and peer with. Empty string skips peering until that module exists and the network has been created."
  type        = string
  default     = ""
}

resource "google_compute_network" "kafka_lab" {
  name                    = "kafka-kraft-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "kafka_lab" {
  name          = "kafka-kraft-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.kafka_lab.id

  private_ip_google_access = true
}

resource "google_compute_router" "kafka_lab" {
  name    = "kafka-kraft-router"
  region  = var.region
  network = google_compute_network.kafka_lab.id
}

resource "google_compute_router_nat" "kafka_lab" {
  name                               = "kafka-kraft-nat"
  router                             = google_compute_router.kafka_lab.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

data "google_compute_network" "crdb" {
  count = var.crdb_network_name != "" ? 1 : 0
  name  = var.crdb_network_name
}

data "google_compute_network" "feeder" {
  count = var.feeder_network_name != "" ? 1 : 0
  name  = var.feeder_network_name
}

resource "google_compute_network_peering" "to_crdb" {
  count        = var.crdb_network_name != "" ? 1 : 0
  name         = "kafka-to-crdb-peering"
  network      = google_compute_network.kafka_lab.id
  peer_network = data.google_compute_network.crdb[0].self_link
}

resource "google_compute_network_peering" "to_feeder" {
  count        = var.feeder_network_name != "" ? 1 : 0
  name         = "kafka-to-feeder-peering"
  network      = google_compute_network.kafka_lab.id
  peer_network = data.google_compute_network.feeder[0].self_link
}

output "network_id" {
  description = "Self link/ID of the Kafka VPC"
  value       = google_compute_network.kafka_lab.id
}

output "network_name" {
  description = "Name of the Kafka VPC"
  value       = google_compute_network.kafka_lab.name
}

output "subnetwork_id" {
  description = "Self link/ID of the Kafka subnet, for broker addresses and instances to attach to"
  value       = google_compute_subnetwork.kafka_lab.id
}

output "nat_ips" {
  description = "Cloud NAT's external IP(s) used for outbound traffic from the private brokers"
  value       = google_compute_router_nat.kafka_lab.nat_ips
}