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
# Note for long-lived projects whose effective quotas already exceed the
# preset by >10x: the Cloud Quotas API rejects QuotaPreference creates that
# would lower an existing limit by more than 10% (FAILED_PRECONDITION /
# QUOTA_DECREASE_TOO_LARGE). Set enable_quota_auto_request = false in those
# cases — see infrastructure/gcp/advanced-installation.md for the full path.
#
# Quota IDs verified against the Cloud Quotas API by end-to-end apply on a
# test GCP project (2026-05-07). Mix of HYPHEN-CASE
# (CPUS-ALL-REGIONS-per-project, N2D-CPUS-per-project-region, ...) and
# camelCase (EnterpriseStorageGibPerRegion) is intentional — that's how the
# upstream API exposes them.
# =============================================================================

locals {
  # GPU quota requests — only submitted when GPU support is enabled
  # (var.enable_gpu, default true). Per-SKU regional GPU-count quotas. The
  # preferred value mirrors the deployment_size preset's per-shape node
  # ceiling, which equals the Kueue GPU ClusterQueue admission cap for that
  # SKU (small = 8 L4 / 4 RTX PRO 6000 — see presets.tf and the GPU Kueue
  # queue table in README.md).
  #
  # Like the CPU/storage requests, this does NOT block apply: small bumps
  # auto-approve, larger ones queue for Google review. The empty, scale-to-zero
  # GPU node pools created by gke.tf consume no GPU quota — the regional
  # NVIDIA_*_GPUS quota only binds when a GPU pod triggers a scale-up, so a
  # still-pending request just leaves GPU jobs Pending, never fails the install.
  #
  # Quota IDs verified against the Cloud Quotas API on a test GCP project
  # (2026-06-29):
  #   - L4 has a dedicated per-SKU quota (NVIDIA-L4-GPUS-per-project-region).
  #   - RTX PRO 6000 (Blackwell) has NO dedicated per-SKU quota. Like the other
  #     newest families (B200/H100/H200), it is governed by the unified
  #     GPUS-PER-GPU-FAMILY-per-project-region quota, scoped by a gpu_family
  #     dimension (NVIDIA_RTX_PRO_6000). A plain NVIDIA-RTX-PRO-6000-GPUS-*
  #     quota does not exist and would fail the apply.
  # Gated per-SKU on effective_request_gpu_*_quota (NOT gpu_*_enabled) so the
  # increase is still requested when install.sh has emptied a SKU's pools because
  # its current quota is below the deployment's need — that SKU then runs
  # GPU-less this install and is picked up on re-install once approved. A SKU the
  # region doesn't offer at all has its request flag false, so no pointless
  # request. Bare terraform: the flags follow var.enable_gpu (presets.tf).
  gpu_quota_requests = merge(
    local.effective_request_gpu_l4_quota ? {
      gpu_l4_region = {
        service       = "compute.googleapis.com"
        quota_id      = "NVIDIA-L4-GPUS-per-project-region"
        dimensions    = { region = var.region }
        preferred     = local.preset.gpu_l4_max_nodes_per_shape
        justification = "NVIDIA L4 GPUs per region. Required for Platforma GPU batch jobs (L4 SKU, up to ${local.preset.gpu_l4_max_nodes_per_shape} concurrent for deployment size ${var.deployment_size}). Default quota is often low or 0 on fresh projects."
      }
    } : {},
    local.effective_request_gpu_rtx_pro_6000_quota ? {
      gpu_rtx_pro_6000_region = {
        service       = "compute.googleapis.com"
        quota_id      = "GPUS-PER-GPU-FAMILY-per-project-region"
        dimensions    = { region = var.region, gpu_family = "NVIDIA_RTX_PRO_6000" }
        preferred     = local.preset.gpu_rtx_pro_6000_max_nodes_per_shape
        justification = "NVIDIA RTX PRO 6000 GPUs per region (per-GPU-family quota, gpu_family=NVIDIA_RTX_PRO_6000). Required for Platforma large-VRAM GPU batch jobs (up to ${local.preset.gpu_rtx_pro_6000_max_nodes_per_shape} concurrent for deployment size ${var.deployment_size}). Default quota is often low or 0 on fresh projects."
      }
    } : {}
  )

  # Map of quota requests submitted on apply. GPU entries merge in per-SKU only
  # when that SKU's effective_request_gpu_*_quota flag is set — which follows
  # var.enable_gpu by default, but install.sh can request an increase for a SKU
  # even when its pools are disabled (see gpu_quota_requests above). With GPU
  # off and no per-SKU override, gpu_quota_requests is empty.
  quota_requests = merge({
    cpus_global = {
      service       = "compute.googleapis.com"
      quota_id      = "CPUS-ALL-REGIONS-per-project"
      dimensions    = {}
      preferred     = local.preset.cpus_global_quota
      justification = "Total CPU (all regions). Required for Platforma batch capacity up to ${local.total_batch_cpu} vCPU (NAP-provisioned across n2d/n2 families) plus system/UI overhead for deployment size ${var.deployment_size}."
    }
    n2d_cpus_region = {
      service       = "compute.googleapis.com"
      quota_id      = "N2D-CPUS-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.n2d_cpus_quota
      justification = "N2D (AMD) CPU per region. Primary family for Platforma batch nodes — NAP provisions n2d-* shapes by default. Also used by static n2d-standard-8 system pool and n2d-standard-4 UI pool. Peak total: ${local.total_batch_cpu} vCPU batch + system/UI overhead, deployment size ${var.deployment_size}."
    }
    n2_cpus_region = {
      service       = "compute.googleapis.com"
      quota_id      = "N2-CPUS-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.n2_cpus_quota
      justification = "N2 (Intel) CPU per region. Used by Node Auto-Provisioning as a STOCKOUT fallback when the N2D (AMD) family is unavailable in this zone. Sized to match N2D so NAP can shift the full batch load to the Intel family if needed. Deployment size: ${var.deployment_size}."
    }
    pd_ssd_region = {
      service       = "compute.googleapis.com"
      quota_id      = "SSD-TOTAL-GB-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.pd_ssd_quota_gb
      justification = "Persistent Disk SSD per region. Covers pd-balanced boot disks for system + UI + NAP-provisioned batch nodes (cluster-wide envelope ${local.total_batch_cpu} vCPU) plus database PVC."
    }
    instances_region = {
      service       = "compute.googleapis.com"
      quota_id      = "INSTANCES-per-project-region"
      dimensions    = { region = var.region }
      preferred     = local.preset.instances_quota
      justification = "Compute instances per region. System (1-2) + UI (up to ${local.preset.ui_max_nodes}) + NAP-provisioned batch nodes (cluster-wide envelope ${local.total_batch_cpu} vCPU; node count depends on shape mix the autoscaler picks)."
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
  }, local.gpu_quota_requests)
}

resource "google_cloud_quotas_quota_preference" "platforma" {
  for_each = var.enable_quota_auto_request ? {
    for k, v in local.quota_requests : k => v if !contains(var.skip_quota_requests, k)
  } : {}

  parent = "projects/${var.project_id}"
  # Region-scope the preference name. A QuotaPreference is a project-GLOBAL
  # resource keyed by name, but the regional quotas it targets differ per region
  # (dimensions.region). Without the suffix, two deployments in the same project
  # but different regions (e.g. prod in euw4, farm in euw3 — or three parallel
  # test installs) collide on the same name and silently overwrite each other's
  # requests. The global CPU quota (no region dimension) keeps its bare name.
  name          = "platforma-${replace(each.key, "_", "-")}${lookup(each.value.dimensions, "region", "") != "" ? "-${each.value.dimensions.region}" : ""}"
  service       = each.value.service
  quota_id      = each.value.quota_id
  contact_email = var.contact_email

  quota_config {
    preferred_value = tostring(each.value.preferred)
  }

  dimensions = each.value.dimensions

  justification = each.value.justification

  # QUOTA_DECREASE_PERCENTAGE_TOO_HIGH: the Cloud Quotas API rejects any
  # QuotaPreference create whose preferred_value is <90% of the current
  # effective limit. This fires routinely on projects where someone (a
  # previous deploy, support ticket, dev experiment) already pushed limits
  # above what our preset table requests. Storing a lower preference can't
  # actually downgrade the effective quota (GCP takes max(default, preference,
  # override) on read), so suppressing this safety check is harmless.
  #
  # The provider's ignore_safety_checks is a single-value string — we can
  # only suppress one check. QUOTA_DECREASE_BELOW_USAGE (the previous value)
  # does not fire on destroy in normal flows; dropping it for the percentage
  # check is the right trade for real-world projects.
  ignore_safety_checks = "QUOTA_DECREASE_PERCENTAGE_TOO_HIGH"

  lifecycle {
    # Never rename an existing preference in place. `name` is the immutable
    # Cloud Quotas resource path, so changing it — e.g. a deployment created
    # before the region-suffix scheme, whose state holds the bare
    # "platforma-n2d-cpus-region" name — would force a replace. The API has no
    # DELETE (a QuotaPreference can only be updated, never removed), so the
    # destroy half of that replace fails and aborts the whole apply. Ignoring
    # name changes keeps such deployments upgradeable: existing preferences keep
    # whatever name they were created with, while brand-new ones are still
    # created with the region-scoped name computed above.
    ignore_changes = [name]

    precondition {
      condition     = var.contact_email != ""
      error_message = "contact_email is required when enable_quota_auto_request = true (Google sends approval notifications there)."
    }
  }

  depends_on = [google_project_service.enabled]
}
