# =============================================================================
# Deployment size presets
# =============================================================================
# Single source of truth for size-driven defaults. The preset selected via
# var.deployment_size drives:
#   - Node pool max sizes (UI + batch)
#   - Kueue ClusterQueue quotas
#   - Filestore capacity
#   - Automated quota requests (CPUS_ALL_REGIONS, N2D_CPUS, PD SSD, Filestore)
#
# Per-preset values match the AWS CloudFormation parallelism table so the same
# label (small/medium/large/xlarge) means the same workload capacity on both
# clouds. The "pilot" tier sits below small for solo testing on fresh projects
# (most quotas auto-approve at this level).
#
# Power users can override individual knobs via *_override variables —
# locals.tf below resolves preset → override → final effective value.
# =============================================================================

locals {
  # Per-job caps — fixed across all presets to match AWS runbook.
  # Single job can use up to 62 vCPU / 500 GiB RAM. This is the largest job
  # that fits on an n2d-highmem-64 (64 vCPU / 512 GiB) after GKE daemonset
  # overhead (~2 vCPU, ~12 GiB).
  max_job_cpu       = 62
  max_job_memory_gi = 500

  presets = {
    small = {
      # Small team / testing. Matches AWS small (~4 large parallel jobs).
      # Even at small, the cluster guarantees substantial headroom: up to
      # 4 batch nodes × 64 vCPU / 512 GiB RAM = 256 vCPU / 2 TiB RAM peak.
      parallel_jobs            = 4
      ui_max_nodes             = 4
      filestore_capacity_gb    = 1024
      cpus_global_quota        = 512
      n2d_cpus_quota           = 512
      pd_ssd_quota_gb          = 2048
      filestore_zonal_quota_gb = 1024
      instances_quota          = 32
    }
    medium = {
      # Mid-sized group. Matches AWS medium (~8 large parallel jobs).
      parallel_jobs            = 8
      ui_max_nodes             = 8
      filestore_capacity_gb    = 2048
      cpus_global_quota        = 1024
      n2d_cpus_quota           = 1024
      pd_ssd_quota_gb          = 4096
      filestore_zonal_quota_gb = 2048
      instances_quota          = 48
    }
    large = {
      # Large group. Matches AWS large (~16 large parallel jobs).
      parallel_jobs            = 16
      ui_max_nodes             = 16
      filestore_capacity_gb    = 4096
      cpus_global_quota        = 2048
      n2d_cpus_quota           = 2048
      pd_ssd_quota_gb          = 8192
      filestore_zonal_quota_gb = 4096
      instances_quota          = 64
    }
    xlarge = {
      # Heavy production. Matches AWS xlarge (~32 large parallel jobs).
      # Quota requests at this size typically need human review (24-72h).
      parallel_jobs            = 32
      ui_max_nodes             = 16
      filestore_capacity_gb    = 8192
      cpus_global_quota        = 4096
      n2d_cpus_quota           = 4096
      pd_ssd_quota_gb          = 16384
      filestore_zonal_quota_gb = 8192
      instances_quota          = 128
    }
  }

  preset = local.presets[var.deployment_size]

  # ---------------------------------------------------------------------------
  # Resolved values — override if explicitly set, else preset default.
  # ---------------------------------------------------------------------------
  effective_ui_pool_max_nodes    = coalesce(var.ui_pool_max_nodes, local.preset.ui_max_nodes)
  effective_batch_pool_max_nodes = coalesce(var.batch_pool_max_nodes, local.preset.parallel_jobs)
  effective_workspace_capacity_gb = coalesce(var.workspace_capacity_gb, local.preset.filestore_capacity_gb)

  effective_kueue_max_job_cpu    = coalesce(var.kueue_max_job_cpu, local.max_job_cpu)
  effective_kueue_max_job_memory = coalesce(var.kueue_max_job_memory, "${local.max_job_memory_gi}Gi")

  # Batch queue total = per-preset parallel slots × per-job cap.
  effective_kueue_batch_queue_cpu    = coalesce(var.kueue_batch_queue_cpu, local.preset.parallel_jobs * local.max_job_cpu)
  effective_kueue_batch_queue_memory = coalesce(var.kueue_batch_queue_memory, "${local.preset.parallel_jobs * local.max_job_memory_gi}Gi")
}
