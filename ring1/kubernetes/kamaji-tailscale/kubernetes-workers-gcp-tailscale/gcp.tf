provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

module "nated_network" {
  source  = "git::https://github.com/mgrzybek/terraform-module-gcp-nated-network.git"
}

resource "google_compute_instance" "kamaji_worker" {
  depends_on = [ module.nated_network ]

  count        = var.worker_count
  name         = "worker-gcp-${count.index}"
  hostname     = "worker-gcp-${count.index}.internal"
  machine_type = "e2-medium"
  zone         = var.gcp_zone

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
    }
  }

  network_interface {
    subnetwork = module.nated_network.subnetwork_id
  }

  metadata_startup_script = templatefile("${path.module}/templates/ubuntu-setup.sh.tftpl", {
    tailscale_key       = var.tailscale_oauth_client_secret
    kubeadm_join_command = var.kubeadm_join_command
  })
}
