output "network_id" {
  value = module.network.network_id
}

output "network_name" {
  value = module.network.network_name
}

output "subnetwork_id" {
  value = module.network.subnetwork_id
}

output "subnet_cidr" {
  value = module.network.subnet_cidr
}

output "producer_worker_pool_name" {
  value = google_cloud_run_v2_worker_pool.producer.name
}

output "consumer_worker_pool_name" {
  value = google_cloud_run_v2_worker_pool.consumer.name
}