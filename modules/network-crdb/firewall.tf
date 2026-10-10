resource "google_compute_firewall" "allow_internal" {
  name    = "crdb-lab-allow-internal"
  network = google_compute_network.crdb_lab.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [var.subnet_cidr]
}

resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "crdb-lab-allow-ssh-iap"
  network = google_compute_network.crdb_lab.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }
  # IAP TCP forwarding range
  source_ranges = ["35.235.240.0/20"]
}

# CockroachDB SQL (30257) and DB console (30080) — nodes are private-only now,
# so admin access comes through an IAP tunnel (same as SSH), not a public source IP
resource "google_compute_firewall" "allow_crdb_admin" {
  name    = "crdb-lab-allow-admin-access"
  network = google_compute_network.crdb_lab.name

  allow {
    protocol = "tcp"
    ports    = var.admin_ports
  }
  # IAP range for interactive tunnel access, plus any peered networks
  # (e.g. the feeder subnet) that need direct access.
  source_ranges = concat(["35.235.240.0/20"], var.additional_admin_source_ranges)
}