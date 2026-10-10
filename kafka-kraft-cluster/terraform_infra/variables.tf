variable "project_id" {
  description = "GCP project ID this Kafka cluster deploys into"
  type        = string
}

variable "region" {
  description = "GCP region for the subnet, router, and Cloud NAT"
  type        = string
}

variable "zone" {
  description = "GCP zone for the broker VMs and their data disks"
  type        = string
}

variable "subnet_cidr" {
  description = "CIDR range for the Kafka VPC's subnet. Kept distinct from the CockroachDB module's 10.20.0.0/24 in case the two are ever peered."
  type        = string
}

variable "node_count" {
  description = "Number of Kafka brokers. Each node runs combined broker+controller KRaft roles, so this is also the size of the controller quorum."
  type        = number
  default     = 3
}

variable "machine_type" {
  description = "GCE machine type for each broker VM"
  type        = string
  default     = "n2-standard-4" # 4 vCPU / 16 GB RAM per broker
}

variable "data_disk_size_gb" {
  description = "Size, in GB, of the dedicated SSD data disk attached to each broker for Kafka log segments (kept separate from the boot disk)"
  type        = number
  default     = 500
}

variable "broker_port" {
  description = "TCP port brokers use for client/broker traffic"
  type        = number
  default     = 9092
}

variable "controller_port" {
  description = "TCP port brokers use for KRaft controller quorum traffic"
  type        = number
  default     = 9093
}

variable "data_mount_path" {
  description = "Filesystem path where the XFS-formatted data disk is mounted on each broker, and where Kafka's log.dirs points"
  type        = string
  default     = "/kafka"
}

variable "kafka_version" {
  description = "Apache Kafka release version to install"
  type        = string
  default     = "4.3.1"
}

variable "scala_version" {
  description = "Scala build version matching the chosen Kafka release (part of the official tarball filename)"
  type        = string
  default     = "2.13"
}

variable "broker_tag" {
  description = "Network tag applied to broker instances; passed to the network module so firewall rules stay scoped to exactly these instances"
  type        = string
  default     = "kafka-broker"
}

variable "client_source_ranges" {
  description = "CIDR ranges allowed to reach the broker port for Kafka client traffic — e.g. the Python feeder's subnet once that module exists. Left empty for now; fill in once the feeder VPC's range is known, or rely on VPC peering + tags instead."
  type        = list(string)
  default     = []
}

variable "crdb_network_name" {
  description = "Name of the existing CockroachDB VPC (e.g. \"crdb-lab-network\"), looked up via data source rather than hand-copying a self link. Current design keeps Kafka and CockroachDB logically separate (no direct peering) — the Python feeder talks to both instead. Leave as empty string unless that changes."
  type        = string
  default     = ""
}

variable "feeder_network_name" {
  description = "Name of the Python feeder service's VPC, looked up via data source and peered with this one. Empty string skips peering until that module exists and the network has been created."
  type        = string
  default     = ""
}
