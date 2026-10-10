output "node_internal_ips" {
  value = google_compute_instance.rke2_node[*].network_interface.0.network_ip
}

output "nat_ip_addresses" {
  description = "Cloud NAT's external IP(s) used for outbound traffic from the private nodes"
  value       = module.network.nat_ips
}