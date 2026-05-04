# =============================================================================
# Automated quota requests
# =============================================================================
# Fresh GCP projects ship with quotas that block any non-trivial Platforma
# install. This file submits quota-increase requests via the Cloud Quotas API
# (google_cloud_quotas_quota_preference) using preset values.
#
# Behavior:
#   - Small bumps (within ~2x of current limit) auto-approve in seconds.
#   - Large bumps (xlarge tier, raw values >2x) typically require human review
#     by Google Cloud Support (usually 24-72h, sometimes minutes).
#   - The Terraform apply does NOT block waiting for approval. If the requested
#     quota is still pending when later resources try to use it, those resources
#     fail with a quota-exceeded error and the user must wait for approval and
#     re-run the apply.
#
# Disable via var.enable_quota_auto_request = false if managing quotas manually.
#
# TODO (Phase 2 testing): verify the exact `quota_id` values against the
# Cloud Quotas API. Some IDs use camelCase (EnterpriseStorageGibPerRegion)
# vs HYPHEN-CASE (CPUS-per-project-region). Run the apply and adjust if
# the API rejects any IDs.
# =============================================================================

locals {
  # Map of quota requests submitted on apply.
  quota_requests = {
    cpus_global = {
      service       = "compute.googleapis.com"
      quota_id      = "CPUS-ALL-REGIONS-per-project"
      dimensions    = {}
      preferred     = local.preset.cpus_global_quota
      justification = "Total CPU (all regions). Required for Platforma batch nodes scaling up to ${local.total_batch_max_nodes} nodes (${local.total_batch_cpu} vCPU peak) across 5 batch pool shapes for deployment size ${var.deployment_size}."
    }
    n2d_cpus_region = {
      service       = "compute.googleapis.com"
      quota_id      = "N2D-CPUS-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.n2d_cpus_quota
      justification = "N2D CPU per region. Platforma uses 5 batch pool shapes (n2d-standard-16/32/64, n2d-highmem-32/64) plus n2d-standard-4 system+UI nodes. Peak total: ${local.total_batch_cpu} vCPU batch + system/UI overhead, deployment size ${var.deployment_size}."
    }
    pd_ssd_region = {
      service       = "compute.googleapis.com"
      quota_id      = "SSD-TOTAL-GB-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.pd_ssd_quota_gb
      justification = "Persistent Disk SSD per region. Covers pd-balanced boot disks for system+UI+batch nodes (up to ${local.total_batch_max_nodes} batch nodes peak across 5 pools) plus database PVC."
    }
    instances_region = {
      service       = "compute.googleapis.com"
      quota_id      = "INSTANCES-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.instances_quota
      justification = "Compute instances per region. System (2) + UI (up to ${local.preset.ui_max_nodes}) + batch (up to ${local.total_batch_max_nodes} across 5 pool shapes) nodes for Platforma."
    }
    filestore_zonal_region = {
      service       = "file.googleapis.com"
      quota_id      = "EnterpriseStorageGibPerRegion"
      dimensions    = { region = var.region }
      preferred     = local.preset.filestore_zonal_quota_gb
      justification = "Filestore Zonal/Regional/Enterprise SSD. Default quota is 0 on fresh projects; required for the recommended ZONAL tier workspace storage."
    }
    in_use_addresses_region = {
      service       = "compute.googleapis.com"
      quota_id      = "IN-USE-ADDRESSES-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.in_use_addresses_quota
      justification = "In-use external IPs per region. With private nodes + Cloud NAT, only NAT IPs (1-2) and the GKE Gateway static IP consume this quota. Default is 8; we request modest headroom."
    }
  }
}

resource "google_cloud_quotas_quota_preference" "platforma" {
  for_each = var.enable_quota_auto_request ? {
    for k, v in local.quota_requests : k => v if !contains(var.skip_quota_requests, k)
  } : {}

  parent        = "projects/${var.project_id}"
  name          = "platforma-${replace(each.key, "_", "-")}"
  service       = each.value.service
  quota_id      = each.value.quota_id
  contact_email = var.contact_email

  quota_config {
    preferred_value = tostring(each.value.preferred)
  }

  dimensions = each.value.dimensions

  justification = each.value.justification

  # QUOTA_DECREASE_BELOW_USAGE: needed for graceful destroy when current usage
  # exceeds new preferred value but everything is being torn down anyway.
  # The provider only accepts a single value (despite the doc); preset values
  # have been bumped in presets.tf so they don't trip QUOTA_DECREASE_PERCENTAGE_TOO_HIGH
  # against typical GCP default quotas.
  ignore_safety_checks = "QUOTA_DECREASE_BELOW_USAGE"

  lifecycle {
    precondition {
      condition     = var.contact_email != ""
      error_message = "contact_email is required when enable_quota_auto_request = true (Google sends approval notifications there)."
    }
  }

  depends_on = [google_project_service.enabled]
}
