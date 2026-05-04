# =============================================================================
# Outputs — what the user needs after deployment
# =============================================================================
# Tier 1 (basic user, just deployed): platforma_url, default_username,
#   password_secret_console_url, post_deploy_steps.
# Tier 2 (debugging / power user): kubectl/port-forward commands, GCS bucket
#   name, cluster name/region/zone.
# =============================================================================

# -----------------------------------------------------------------------------
# Application access
# -----------------------------------------------------------------------------

output "platforma_url" {
  description = "Endpoint to connect the Platforma Desktop App. HTTPS when ingress_enabled=true; otherwise the user must port-forward (see port_forward_command)."
  value       = var.ingress_enabled ? "https://${var.domain_name}" : "(ingress disabled — use port_forward_command, then connect Desktop App to grpc://localhost:6345)"
}

output "default_username" {
  description = "Default admin username (htpasswd auth)."
  value       = var.admin_username
}

output "password_secret_console_url" {
  description = "Cloud Console URL to view the auto-generated admin password. Click → Secret Manager → 'View secret value'."
  value       = "https://console.cloud.google.com/security/secret-manager/secret/${google_secret_manager_secret.admin_password.secret_id}/versions?project=${var.project_id}"
}

output "password_retrieve_command" {
  description = "CLI command to fetch the admin password (alternative to the Console URL)."
  value       = "gcloud secrets versions access latest --secret=${google_secret_manager_secret.admin_password.secret_id} --project=${var.project_id}"
}

locals {
  _password_console_url = "https://console.cloud.google.com/security/secret-manager/secret/${google_secret_manager_secret.admin_password.secret_id}/versions?project=${var.project_id}"
  _password_cli_command = "gcloud secrets versions access latest --secret=${google_secret_manager_secret.admin_password.secret_id} --project=${var.project_id}"

  # Credentials step text — branches on auth method so the post-deploy
  # instructions match what the user actually configured. For LDAP and
  # user-supplied htpasswd content, the auto-generated Secret Manager URL is
  # irrelevant; for htpasswd auto-gen it's the only way to discover the
  # password (avoids printing it to TF state outputs).
  #
  # nonsensitive() wrap: htpasswd_content is sensitive, so any expression
  # touching it inherits sensitivity. Whether it is empty is not sensitive,
  # so we extract that boolean explicitly — without this, post_deploy_steps
  # itself becomes sensitive and TF refuses to print it.
  _htpasswd_provided = nonsensitive(length(var.htpasswd_content) > 0)
  _auth_step = (
    var.auth_method == "ldap" ?
    "Log in with your LDAP credentials (server: ${var.ldap_server})." :
    local._htpasswd_provided ?
    "Log in with one of the user/password pairs from your htpasswd_content." :
    "Retrieve the auto-generated admin password (username '${var.admin_username}'):\n       Open: ${local._password_console_url}\n       (or run: ${local._password_cli_command})"
  )

  _post_deploy_steps_with_ingress = <<-EOT
    Platforma is being deployed. Once the deploy completes:

    1. Wait for the TLS certificate to provision (5-15 min after deploy).
       Check: gcloud certificate-manager certificates describe ${var.cluster_name}-cert --location=global --project=${var.project_id}
       Status should be ACTIVE.

    2. ${local._auth_step}

    3. Open the Platforma Desktop App, click "Add Connection" → "Remote Server",
       and connect to https://${var.domain_name}.
  EOT

  _post_deploy_steps_port_forward = <<-EOT
    Platforma is being deployed. Once the deploy completes:

    1. Authenticate kubectl to the cluster:
       gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${local.zone} --project ${var.project_id}

    2. Start a port-forward (leave running):
       kubectl port-forward -n ${var.platforma_namespace} svc/${var.helm_release_name} 6345:6345

    3. ${local._auth_step}

    4. Open the Platforma Desktop App, click "Add Connection" → "Remote Server",
       and connect to grpc://localhost:6345.

    For production, set ingress_enabled=true with domain_name + dns_zone_name to enable HTTPS access.
  EOT
}

output "post_deploy_steps" {
  description = "What to do after the deploy completes."
  value       = var.ingress_enabled ? local._post_deploy_steps_with_ingress : local._post_deploy_steps_port_forward
}

# -----------------------------------------------------------------------------
# Cluster operations (power user / debugging)
# -----------------------------------------------------------------------------

output "kubectl_credentials_command" {
  description = "Command to populate kubeconfig for kubectl access to the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${local.zone} --project ${var.project_id}"
}

output "port_forward_command" {
  description = "Port-forward to the Platforma gRPC service (for development / fallback when ingress is disabled)."
  value       = "kubectl port-forward -n ${var.platforma_namespace} svc/${var.helm_release_name} 6345:6345"
}

# -----------------------------------------------------------------------------
# Resources
# -----------------------------------------------------------------------------

output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.primary.name
}

output "cluster_endpoint" {
  description = "GKE control plane endpoint."
  value       = google_container_cluster.primary.endpoint
  sensitive   = true
}

output "region" {
  description = "GCP region the cluster runs in."
  value       = var.region
}

output "zone" {
  description = "GCP zone for zonal resources (Filestore, persistent disks)."
  value       = local.zone
}

output "gcs_bucket" {
  description = "Primary GCS bucket name (Platforma stores results here; visible in Desktop App)."
  value       = google_storage_bucket.primary.name
}

output "ingress_ip" {
  description = "Static external IP of the Platforma load balancer (only when ingress_enabled=true)."
  value       = var.ingress_enabled ? google_compute_global_address.ingress[0].address : null
}
