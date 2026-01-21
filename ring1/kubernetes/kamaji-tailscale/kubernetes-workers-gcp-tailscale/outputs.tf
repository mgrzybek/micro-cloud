# Affiche les IPs privées GCP (réseau NATé)
output "gcp_private_ips" {
  description = "Adresses IP privées des instances dans le VPC Google"
  value       = google_compute_instance.kamaji_worker[*].network_interface[0].network_ip
}

# Commande pratique pour se connecter sans IP publique
output "ssh_commands" {
  description = "Commandes SSH pour se connecter aux workers via Tailscale"
  value       = [for i in google_compute_instance.kamaji_worker : "tailscale ssh ${i.name}"]
}
