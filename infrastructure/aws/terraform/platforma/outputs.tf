# =============================================================================
# Outputs — how to reach Platforma and retrieve the bootstrap credentials
# =============================================================================

output "platforma_namespace" {
  description = "Namespace Platforma and its controllers run in."
  value       = var.platforma_namespace
}

output "platforma_release_name" {
  description = "Helm release name (null when deploy_platforma = false)."
  value       = var.deploy_platforma ? var.helm_release_name : null
}

output "platforma_url" {
  description = "Platforma endpoint. External DNS publishes this host into the Route53 zone; allow a few minutes after apply for DNS + the ALB to come up. Null when ingress is disabled (reach the service via port-forward)."
  value       = var.ingress_enabled ? "https://${var.domain_name}" : null
}

output "auth_method" {
  description = "Active authentication method."
  value       = var.auth_method
}

output "htpasswd_username" {
  # The condition derives from the sensitive htpasswd_content var, but whether a
  # user was auto-generated (and the fixed name "platforma") is not itself a
  # secret — unmark it so the output isn't suppressed.
  description = "Auto-generated htpasswd username (null unless htpasswd auth auto-generated a user)."
  value       = nonsensitive(local.htpasswd_auto_generated) ? "platforma" : null
}

output "htpasswd_password_command" {
  description = "Command to fetch the auto-generated 'platforma' user password from SSM (null unless one was generated). The command output is the secret, not this string."
  value = nonsensitive(local.htpasswd_auto_generated) ? join(" ", [
    "aws ssm get-parameter",
    "--name /${var.cluster_name}/platforma/users-password",
    "--with-decryption --region ${var.region}",
    "--query Parameter.Value --output text",
  ]) : null
}

output "configured_data_sources" {
  description = "Names of the data libraries exposed in the Desktop App (configured libraries plus the demo library when enabled)."
  value       = [for ds in local.data_sources : ds.name]
}
