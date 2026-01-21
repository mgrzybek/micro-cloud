# --- Configuration Kubernetes ---
variable "worker_count" {
  description = "The number of workers to deploy on GCE"
  type = number
  default = 1
}

variable "kubeadm_join_command" {
  description = "The commmand to run to make the workers join the controlplane"
  type = string
}

# --- Configuration Tailscale ---
variable "tailscale_oauth_client_id" {
  description = "Clé API ou Access Token pour le provider Tailscale"
  type        = string
  sensitive   = true
}

variable "tailscale_oauth_client_secret" {
  description = "Clé d'authentification (Auth Key) pour enregistrer les VMs GCP dans Tailscale"
  type        = string
  sensitive   = true
}

# --- Configuration GCP ---
variable "gcp_project_id" {
  description = "L'ID de votre projet Google Cloud"
  type        = string
}

variable "gcp_region" {
  description = "La région GCP pour le déploiement"
  type        = string
  default     = "europe-west9"
}

variable "gcp_zone" {
  description = "La zone GCP pour les instances"
  type        = string
  default     = "europe-west9-b"
}
