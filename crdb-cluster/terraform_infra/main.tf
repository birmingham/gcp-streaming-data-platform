module "network" {
  source                         = "../../modules/network-crdb"
  region                         = var.region
  feeder_network_name            = var.feeder_network_name
  additional_admin_source_ranges = var.additional_admin_source_ranges
}

# Shared RKE2 cluster token. Generated once by Terraform and handed to every
# node (bootstrap node uses it as its own secret; joining nodes use it to
# authenticate) so there's no manual "copy the token off node 0" step.
resource "random_password" "rke2_token" {
  length  = 32
  special = false
}

# Static internal IPs, reserved before any instance exists, so every node's
# tls-san list (and the join target for nodes 1/2) is known up front instead
# of depending on another instance's dynamically-assigned IP at boot time.
resource "google_compute_address" "crdb_node_ip" {
  count        = var.node_count
  name         = "crdb-lab-node-ip-${count.index}"
  address_type = "INTERNAL"
  subnetwork   = module.network.subnetwork_id
  region       = var.region
}

resource "google_compute_instance" "rke2_node" {
  count                     = var.node_count
  name                      = "crdb-lab-node-${count.index}"
  machine_type              = var.machine_type
  zone                      = var.zone
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
      size  = 50
      type  = "pd-ssd"
    }
  }

  # Separate data disk per node for CockroachDB storage
  attached_disk {
    source      = google_compute_disk.crdb_data[count.index].id
    device_name = "crdb-data"
  }

  network_interface {
    subnetwork = module.network.subnetwork_id
    network_ip = google_compute_address.crdb_node_ip[count.index].address
  }

  tags = ["crdb-lab", "rke2-node"]

  metadata = {
    enable-oslogin = "TRUE"
    startup-script = templatefile("../templates/rke2-startup.sh.tpl", {
      token      = random_password.rke2_token.result
      node_name  = "crdb-lab-node-${count.index}"
      node_index = count.index
      # Node 0 bootstraps a new cluster (empty server_url); nodes 1+ join it
      # via node 0's reserved private IP on the RKE2 supervisor port.
      server_url = count.index == 0 ? "" : "https://${google_compute_address.crdb_node_ip[0].address}:9345"
      # Every node's cert needs to recognize every node's IP, not just its
      # own — this is the SAN mismatch you already hit in the other lab.
      tls_sans = concat(
        google_compute_address.crdb_node_ip[*].address,
        ["localhost", "127.0.0.1"]
      )
      rke2_version = var.rke2_version
    })
  }

  labels = {
    environment = "lab"
    project     = "cockroachdb-lab"
  }
}

resource "google_compute_disk" "crdb_data" {
  count = var.node_count
  name  = "crdb-lab-data-${count.index}"
  type  = "pd-ssd"
  zone  = var.zone
  size  = var.data_disk_size_gb
}
