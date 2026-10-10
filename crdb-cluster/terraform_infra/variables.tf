variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-west1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "us-west1-a"
}

variable "node_count" {
  description = "Number of nodes for the CockroachDB cluster (3 or 5 recommended for quorum testing)"
  type        = number
  default     = 5
}

variable "machine_type" {
  description = "GCE machine type"
  type        = string
  default     = "e2-standard-4"
}

variable "data_disk_size_gb" {
  description = "Size of the dedicated CockroachDB data disk per node"
  type        = number
  default     = 200
}

variable "rke2_version" {
  description = "Pinned RKE2 version for the install script. Pinning avoids a known install-script bug where the 'stable' channel briefly resolves to a release before its checksum/tarball assets are fully uploaded (recurring GitHub issue on rancher/rke2), causing a 404 during install."
  type        = string
  default     = "v1.36.4+rke2r1"
}

variable "feeder_network_name" {
  description = "Name of the existing Python feeder VPC to look up via data source and peer with. Empty string skips peering."
  type        = string
  default     = ""
}

variable "additional_admin_source_ranges" {
  description = "Extra CIDR ranges allowed to reach the CockroachDB admin ports (26257, 8080), in addition to the IAP range — e.g. the Python feeder's subnet"
  type        = list(string)
  default     = []
}