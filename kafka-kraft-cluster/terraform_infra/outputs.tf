output "broker_internal_ips" {
  description = "Static internal IPs of the Kafka brokers, in node-ID order"
  value       = google_compute_address.kafka_node_ip[*].address
}

output "bootstrap_servers" {
  description = "Comma-separated broker:port list for Kafka clients (e.g. the Python feeder) to use as bootstrap.servers"
  value = join(",", [
    for addr in google_compute_address.kafka_node_ip[*].address :
    "${addr}:${var.broker_port}"
  ])
}

output "kraft_cluster_id" {
  description = "The KRaft cluster ID generated once and shared identically across all brokers"
  value       = random_uuid.kraft_cluster_id.result
}

output "nat_ip_addresses" {
  description = "Cloud NAT's external IP(s) used for outbound traffic from the private brokers"
  value       = module.network.nat_ips
}
