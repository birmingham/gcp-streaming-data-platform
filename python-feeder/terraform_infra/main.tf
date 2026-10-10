# =============================================================================
# Python feeder — network + Cloud Run Worker Pools
#
# Worker Pools, not Services: producer.py and consumer.py are infinite
# loops with no HTTP listener, so a Service (which requires the container
# to serve HTTP and pass health checks) is the wrong fit. Worker Pools are
# built for exactly this — continuously-running, non-HTTP background
# processes — with Direct VPC egress and manual (not request-driven)
# scaling. No Cloud NAT: egress is PRIVATE_RANGES_ONLY, so only traffic
# to CockroachDB's/Kafka's private IPs routes through this VPC; the
# container's other outbound needs (pulling the image, etc.) use Cloud
# Run's default path outside this VPC entirely.
# =============================================================================

module "network" {
  source = "../../modules/network-feeder"

  region             = var.region
  subnet_cidr        = var.subnet_cidr
  crdb_network_name  = var.crdb_network_name
  kafka_network_name = var.kafka_network_name
}

resource "google_cloud_run_v2_worker_pool" "producer" {
  name         = "python-feeder-producer"
  location     = var.region
  launch_stage = "BETA"

  deletion_protection = false

  scaling {
    scaling_mode          = "MANUAL"
    manual_instance_count = 1
  }

  template {
    containers {
      image = var.feeder_image

      env {
        name  = "MODE"
        value = "producer"
      }
      env {
        name  = "KAFKA_BOOTSTRAP_SERVERS"
        value = var.kafka_bootstrap_servers
      }
      env {
        name  = "KAFKA_TOPIC"
        value = var.kafka_topic
      }
      env {
        name  = "PRODUCE_INTERVAL_SECONDS"
        value = var.produce_interval_seconds
      }
      env {
        name  = "DEVICE_COUNT"
        value = var.device_count
      }
    }

    vpc_access {
      network_interfaces {
        network    = module.network.network_id
        subnetwork = module.network.subnetwork_id
        tags       = []
      }
      egress = "PRIVATE_RANGES_ONLY"
    }
  }
}

resource "google_cloud_run_v2_worker_pool" "consumer" {
  name         = "python-feeder-consumer"
  location     = var.region
  launch_stage = "BETA"

  deletion_protection = false

  scaling {
    scaling_mode          = "MANUAL"
    manual_instance_count = 1
  }

  template {
    containers {
      image = var.feeder_image

      env {
        name  = "MODE"
        value = "consumer"
      }
      env {
        name  = "KAFKA_BOOTSTRAP_SERVERS"
        value = var.kafka_bootstrap_servers
      }
      env {
        name  = "KAFKA_TOPIC"
        value = var.kafka_topic
      }
      env {
        name  = "KAFKA_CONSUMER_GROUP"
        value = var.kafka_consumer_group
      }
      env {
        name  = "CRDB_CONN_STRING"
        value = var.crdb_conn_string
      }
    }

    vpc_access {
      network_interfaces {
        network    = module.network.network_id
        subnetwork = module.network.subnetwork_id
        tags       = []
      }
      egress = "PRIVATE_RANGES_ONLY"
    }
  }
}