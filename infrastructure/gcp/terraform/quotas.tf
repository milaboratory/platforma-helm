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
      justification = "Total CPU (all regions). Required for Platforma batch nodes scaling up to ${local.preset.parallel_jobs} parallel jobs (deployment size: ${var.deployment_size})."
    }
    n2d_cpus_region = {
      service       = "compute.googleapis.com"
      quota_id      = "N2D-CPUS-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.n2d_cpus_quota
      justification = "N2D CPU per region. Platforma batch pool uses n2d-highmem-64 nodes (${local.preset.parallel_jobs} max nodes for deployment size ${var.deployment_size})."
    }
    pd_ssd_region = {
      service       = "compute.googleapis.com"
      quota_id      = "SSD-TOTAL-GB-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.pd_ssd_quota_gb
      justification = "Persistent Disk SSD per region. Covers pd-balanced node boot disks across system+UI+batch pools plus the database PVC."
    }
    instances_region = {
      service       = "compute.googleapis.com"
      quota_id      = "INSTANCES-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.instances_quota
      justification = "Compute instances per region. System (2) + UI (up to ${local.preset.ui_max_nodes}) + batch (up to ${local.preset.parallel_jobs}) nodes for Platforma."
    }
    filestore_zonal_region = {
      service       = "file.googleapis.com"
      quota_id      = "EnterpriseStorageGibPerRegion"
      dimensions    = { region = var.region }
      preferred     = local.preset.filestore_zonal_quota_gb
      justification = "Filestore Zonal/Regional/Enterprise SSD. Default quota is 0 on fresh projects; required for the recommended ZONAL tier workspace storage."
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
