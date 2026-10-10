variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "us-west1"
}

variable "subnet_cidr" {
  description = "CIDR range for the feeder VPC's subnet"
  type        = string
  default     = "10.40.0.0/24"
}

variable "crdb_network_name" {
  description = "Name of the existing CockroachDB VPC to peer with. Empty string skips peering."
  type        = string
  default     = "crdb-lab-network"
}

variable "kafka_network_name" {
  description = "Name of the existing Kafka VPC to peer with. Empty string skips peering."
  type        = string
  default     = "kafka-kraft-network"
}

variable "feeder_image" {
  description = "Artifact Registry image URL for the feeder container, built via gcloud builds submit"
  type        = string
}

variable "kafka_bootstrap_servers" {
  description = "Comma-separated broker:port list — copy from `terraform output bootstrap_servers` in kafka-kraft-cluster/terraform_infra"
  type        = string
}

variable "kafka_topic" {
  description = "Kafka topic the producer publishes to and the consumer reads from"
  type        = string
  default     = "feeder-events"
}

variable "kafka_consumer_group" {
  description = "Kafka consumer group ID for the consumer worker pool"
  type        = string
  default     = "feeder-consumer"
}

variable "crdb_conn_string" {
  description = "Postgres-wire connection string for CockroachDB, e.g. postgresql://user@<node-ip>:30257/defaultdb?sslmode=require"
  type        = string
  sensitive   = true
}

variable "produce_interval_seconds" {
  description = "Seconds between synthetic events produced"
  type        = string
  default     = "1"
}

variable "device_count" {
  description = "Number of distinct simulated device_ids"
  type        = string
  default     = "10"
}