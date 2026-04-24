output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = local.zone
}

output "cluster_name" {
  value = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  value     = google_container_cluster.primary.endpoint
  sensitive = true
}

output "get_credentials_command" {
  value = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${local.zone} --project ${var.project_id}"
}

output "gcs_bucket" {
  value = google_storage_bucket.primary.name
}

output "filestore_ip" {
  value = google_filestore_instance.workspace.networks[0].ip_addresses[0]
}

output "filestore_share" {
  value = google_filestore_instance.workspace.file_shares[0].name
}

output "server_sa_email" {
  value = google_service_account.server.email
}

output "jobs_sa_email" {
  value = google_service_account.jobs.email
}

output "admin_username" {
  value = var.admin_username
}

output "admin_password_secret_manager_path" {
  value = "projects/${var.project_id}/secrets/${google_secret_manager_secret.admin_password.secret_id}/versions/latest"
}

output "admin_password_retrieve_command" {
  value = "gcloud secrets versions access latest --secret=${google_secret_manager_secret.admin_password.secret_id} --project=${var.project_id}"
}

output "port_forward_command" {
  value = "kubectl port-forward -n ${var.platforma_namespace} svc/${var.helm_release_name} 6345:6345"
}
