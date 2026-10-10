# =============================================================================
# CockroachDB lab network module
#
# Owns the VPC, subnet, and Cloud NAT for the CockroachDB lab cluster.
# Firewall rules live in ./firewall.tf. Node-specific resources (static
# IPs, disks, instances) stay in the root module and consume this
# module's outputs.
# =============================================================================

variable "region" {
  description = "GCP region for the subnet, router, and Cloud NAT"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR range for the subnetwork; also used as the allowed source range for internal traffic"
  type        = string
  default     = "10.20.0.0/24"
}

variable "admin_ports" {
  description = "TCP ports allowed for CockroachDB admin access via IAP tunnel (SQL + DB console)"
  type        = list(string)
  default     = ["26257", "8080"]
}

variable "additional_admin_source_ranges" {
  description = "Extra CIDR ranges allowed to reach the CockroachDB admin ports (26257, 8080), in addition to the IAP range — e.g. the Python feeder's subnet"
  type        = list(string)
  default     = []
}

variable "feeder_network_name" {
  description = "Name of the existing Python feeder VPC to look up via data source and peer with. Empty string skips peering."
  type        = string
  default     = ""
}

resource "google_compute_network" "crdb_lab" {
  name                    = "crdb-lab-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "crdb_lab" {
  name          = "crdb-lab-subnet"
  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.crdb_lab.id
}

resource "google_compute_router" "crdb_lab" {
  name    = "crdb-lab-router"
  region  = var.region
  network = google_compute_network.crdb_lab.id
}

resource "google_compute_router_nat" "crdb_lab" {
  name                               = "crdb-lab-nat"
  router                             = google_compute_router.crdb_lab.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# -----------------------------------------------------------------------
# VPC peering to the Python feeder network — the matching
# google_compute_network_peering resource lives in modules/network-feeder,
# pointing back at this network.
# -----------------------------------------------------------------------

data "google_compute_network" "feeder" {
  count = var.feeder_network_name != "" ? 1 : 0
  name  = var.feeder_network_name
}

resource "google_compute_network_peering" "to_feeder" {
  count        = var.feeder_network_name != "" ? 1 : 0
  name         = "crdb-to-feeder-peering"
  network      = google_compute_network.crdb_lab.id
  peer_network = data.google_compute_network.feeder[0].self_link
}

output "network_id" {
  value = google_compute_network.crdb_lab.id
}

output "network_name" {
  value = google_compute_network.crdb_lab.name
}

output "subnetwork_id" {
  value = google_compute_subnetwork.crdb_lab.id
}

output "nat_ips" {
  description = "Cloud NAT's external IP(s) used for outbound traffic from the private nodes"
  value       = google_compute_router_nat.crdb_lab.nat_ips
}