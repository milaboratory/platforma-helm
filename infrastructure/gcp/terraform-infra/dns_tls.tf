# =============================================================================
# DNS + TLS — GCP-side resources
# =============================================================================
# Gated on var.ingress_enabled. When enabled, this provisions:
#   1. A reserved global static IP for the load balancer
#   2. A Cloud DNS A record pointing domain_name at that IP
#   3. A Certificate Manager DNS-authorization record (CNAME in the zone)
#   4. A Google-managed cert validated via DNS authorization
#   5. A Cert Map entry binding cert ↔ hostname
#
# The K8s-side Gateway + HTTPRoute + HealthCheckPolicy + GFE cleanup wait
# live in the platforma module (helm/infrastructure/gcp/terraform-platforma).
#
# Cert issuance + DNS propagation usually completes in 5-15 min after apply.
# =============================================================================

locals {
  dns_project = var.dns_zone_project != "" ? var.dns_zone_project : var.project_id
}

# -- Static external IP for the load balancer
resource "google_compute_global_address" "ingress" {
  count = var.ingress_enabled ? 1 : 0

  name    = "${var.cluster_name}-ingress"
  project = var.project_id

  lifecycle {
    precondition {
      condition     = var.domain_name != "" && var.dns_zone_name != ""
      error_message = "domain_name and dns_zone_name are required when ingress_enabled = true."
    }
  }

  depends_on = [google_project_service.enabled]
}

# -- A record: domain_name → static IP
resource "google_dns_record_set" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  project      = local.dns_project
  managed_zone = var.dns_zone_name
  name         = "${var.domain_name}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.ingress[0].address]

  depends_on = [google_project_service.enabled]
}

# -- DNS authorization for Certificate Manager (proves we control the domain)
resource "google_certificate_manager_dns_authorization" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name        = "${var.cluster_name}-dns-auth"
  project     = var.project_id
  location    = "global"
  domain      = var.domain_name
  description = "DNS authorization for Platforma TLS cert"

  depends_on = [google_project_service.enabled]
}

# -- CNAME validation record (created in the user's zone, points at GCP-managed target)
resource "google_dns_record_set" "cert_validation" {
  count = var.ingress_enabled ? 1 : 0

  project      = local.dns_project
  managed_zone = var.dns_zone_name
  name         = google_certificate_manager_dns_authorization.platforma[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.platforma[0].dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.platforma[0].dns_resource_record[0].data]

  depends_on = [google_project_service.enabled]
}

# -- Google-managed certificate
resource "google_certificate_manager_certificate" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name        = "${var.cluster_name}-cert"
  project     = var.project_id
  location    = "global"
  description = "Platforma TLS certificate (managed by Certificate Manager)"

  managed {
    domains            = [var.domain_name]
    dns_authorizations = [google_certificate_manager_dns_authorization.platforma[0].id]
  }

  depends_on = [
    google_dns_record_set.cert_validation,
    google_project_service.enabled,
  ]
}

# -- Cert map (Gateway references the map, not individual certs)
resource "google_certificate_manager_certificate_map" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name        = "${var.cluster_name}-cert-map"
  project     = var.project_id
  description = "Platforma cert map for Gateway"

  depends_on = [google_project_service.enabled]
}

resource "google_certificate_manager_certificate_map_entry" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name         = "${var.cluster_name}-cert-entry"
  project      = var.project_id
  map          = google_certificate_manager_certificate_map.platforma[0].name
  certificates = [google_certificate_manager_certificate.platforma[0].id]
  hostname     = var.domain_name

  depends_on = [google_project_service.enabled]
}
