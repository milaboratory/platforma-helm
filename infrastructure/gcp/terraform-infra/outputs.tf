# =============================================================================
# Infra module outputs — consumed by the platforma module
# =============================================================================
# The platforma module reads cluster/storage/IAM details via data sources keyed
# on identifiers shared with this module (project_id, cluster_name, etc.). For
# transparency and to help install.sh wire the two together, we also expose
# the concrete values here.
# =============================================================================

# -----------------------------------------------------------------------------
# Identifiers — used by the platforma module's data sources and as install.sh
# inputs for the second-stage deployment.
# -----------------------------------------------------------------------------

output "project_id" {
  description = "GCP project the cluster was created in."
  value       = var.project_id
}

output "region" {
  description = "GCP region of regional resources."
  value       = var.region
}

output "zone" {
  description = "GCP zone for zonal resources (Filestore, batch node pools)."
  value       = local.zone
}

output "cluster_name" {
  description = "GKE cluster name. Pass-through of var.cluster_name; the platforma module uses var.cluster_name directly (not this output) as its data.google_container_cluster lookup key."
  value       = google_container_cluster.primary.name
}

output "cluster_location" {
  description = "GKE cluster location (same as zone for this module's zonal cluster)."
  value       = local.zone
}

output "platforma_namespace" {
  description = "Kubernetes namespace the apps module should deploy into."
  value       = var.platforma_namespace
}

output "helm_release_name" {
  description = "Helm release name to use in the platforma module."
  value       = var.helm_release_name
}

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

output "gcs_bucket" {
  description = "Primary GCS bucket name."
  value       = google_storage_bucket.primary.name
}

output "filestore_instance_name" {
  description = "Workspace Filestore instance name."
  value       = google_filestore_instance.workspace.name
}

output "filestore_share_name" {
  description = "Workspace Filestore share name."
  value       = google_filestore_instance.workspace.file_shares[0].name
}

# -----------------------------------------------------------------------------
# Container image cache (quay.io pull-through mirror)
# -----------------------------------------------------------------------------

output "image_cache_registry" {
  description = "Docker endpoint of the quay.io pull-through cache mirror (pl-containers remote repo)."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.pl_containers.repository_id}"
}

output "default_docker_registry" {
  description = "Value for the backend --default-docker-registry flag: cache mirror plus the milaboratories/pl-containers path quay.io serves."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.pl_containers.repository_id}/milaboratories/pl-containers"
}

# -----------------------------------------------------------------------------
# IAM
# -----------------------------------------------------------------------------

output "server_service_account_email" {
  description = "Email of the platforma-server GCP service account."
  value       = google_service_account.server.email
}

output "jobs_service_account_email" {
  description = "Email of the platforma-jobs GCP service account."
  value       = google_service_account.jobs.email
}

# -----------------------------------------------------------------------------
# Ingress (only meaningful when ingress_enabled = true)
# -----------------------------------------------------------------------------

output "ingress_enabled" {
  description = "Pass-through of var.ingress_enabled, for the platforma module."
  value       = var.ingress_enabled
}

output "domain_name" {
  description = "Pass-through of var.domain_name."
  value       = var.domain_name
}

output "ingress_ip_name" {
  description = "Name of the reserved global static IP (only when ingress_enabled = true)."
  value       = var.ingress_enabled ? google_compute_global_address.ingress[0].name : null
}

output "ingress_ip_address" {
  description = "Static external IP address of the Platforma load balancer (only when ingress_enabled = true)."
  value       = var.ingress_enabled ? google_compute_global_address.ingress[0].address : null
}

output "certmap_name" {
  description = "Certificate Manager cert map name to annotate the Gateway with (only when ingress_enabled = true)."
  value       = var.ingress_enabled ? google_certificate_manager_certificate_map.platforma[0].name : null
}

# -----------------------------------------------------------------------------
# User-facing
# -----------------------------------------------------------------------------

output "kubectl_credentials_command" {
  description = "Command to populate kubeconfig for kubectl access to the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${local.zone} --project ${var.project_id}"
}
