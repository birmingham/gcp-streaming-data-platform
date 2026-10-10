resource "google_compute_firewall" "allow_broker_internal" {
  name    = "kafka-kraft-allow-broker-internal"
  network = google_compute_network.kafka_lab.name

  allow {
    protocol = "tcp"
    ports    = [tostring(var.broker_port), tostring(var.controller_port)]
  }
  allow {
    protocol = "icmp"
  }

  source_tags = [var.broker_tag]
  target_tags = [var.broker_tag]
}

resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "kafka-kraft-allow-ssh-iap"
  network = google_compute_network.kafka_lab.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  # IAP TCP forwarding range
  source_ranges = ["35.235.240.0/20"]
  target_tags   = [var.broker_tag]
}

resource "google_compute_firewall" "allow_kafka_client" {
  count   = length(var.client_source_ranges) > 0 ? 1 : 0
  name    = "kafka-kraft-allow-client-access"
  network = google_compute_network.kafka_lab.name

  allow {
    protocol = "tcp"
    ports    = [tostring(var.broker_port)]
  }

  source_ranges = var.client_source_ranges
  target_tags   = [var.broker_tag]
}