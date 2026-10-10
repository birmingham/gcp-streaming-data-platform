# =============================================================================
# Python feeder network module
#
# Owns the VPC and subnet that Cloud Run's Direct VPC egress attaches to,
# plus peering to both the CockroachDB and Kafka VPCs. No Cloud NAT here:
# the Cloud Run service should use "route only private IP ranges" egress,
# so internet-bound traffic never touches this VPC — only traffic destined
# for CockroachDB's/Kafka's private IPs routes through it. VPC peering is
# non-transitive, so peering feeder<->crdb and feeder<->kafka here does
# NOT connect crdb and kafka to each other.
# =============================================================================

variable "region" {
  description = "GCP region for the subnet — must match the Cloud Run service's region for Direct VPC egress"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR range for the feeder VPC's subnet"
  type        = string
  default     = "10.40.0.0/24"
}

variable "crdb_network_name" {
  description = "Name of the existing CockroachDB VPC to look up via data source and peer with. Empty string skips peering."
  type        = string
  default     = ""
}

variable "kafka_network_name" {
  description = "Name of the existing Kafka VPC to look up via data source and peer with. Empty string skips peering."
  type        = string
  default     = ""
}

resource "google_compute_network" "feeder" {
  name                    = "python-feeder-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "feeder" {
  name          = "python-feeder-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.feeder.id

  # Required for Cloud Run's Direct VPC egress to attach to this subnet.
  private_ip_google_access = true
}

# -----------------------------------------------------------------------
# VPC peering — each of these is one side of a two-sided relationship.
# The matching google_compute_network_peering resource must also exist
# in the CockroachDB / Kafka module, pointing back at this network.
# -----------------------------------------------------------------------

data "google_compute_network" "crdb" {
  count = var.crdb_network_name != "" ? 1 : 0
  name  = var.crdb_network_name
}

data "google_compute_network" "kafka" {
  count = var.kafka_network_name != "" ? 1 : 0
  name  = var.kafka_network_name
}

resource "google_compute_network_peering" "to_crdb" {
  count        = var.crdb_network_name != "" ? 1 : 0
  name         = "feeder-to-crdb-peering"
  network      = google_compute_network.feeder.id
  peer_network = data.google_compute_network.crdb[0].self_link
}

resource "google_compute_network_peering" "to_kafka" {
  count        = var.kafka_network_name != "" ? 1 : 0
  name         = "feeder-to-kafka-peering"
  network      = google_compute_network.feeder.id
  peer_network = data.google_compute_network.kafka[0].self_link
}

output "network_id" {
  value = google_compute_network.feeder.id
}

output "network_name" {
  value = google_compute_network.feeder.name
}

output "subnetwork_id" {
  value = google_compute_subnetwork.feeder.id
}

output "subnet_cidr" {
  description = "The feeder subnet's CIDR — feed this into crdb's additional_admin_source_ranges and kafka's client_source_ranges"
  value       = var.subnet_cidr
}