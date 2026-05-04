# =============================================================================
# Deployment size presets
# =============================================================================
# Single source of truth for size-driven defaults. The preset selected via
# var.deployment_size drives:
#   - Per-batch-pool max sizes (5 pool shapes — see batch_pool_specs below)
#   - UI pool max size
#   - Kueue ClusterQueue quotas (computed from per-pool capacity totals)
#   - Filestore capacity
#   - Automated quota requests (CPUS_ALL_REGIONS, N2D_CPUS, PD SSD, Filestore)
#
# Per-preset values match the AWS CloudFormation parallelism table so the same
# label (small/medium/large/xlarge) means the same workload capacity on both
# clouds.
#
# Power users can override individual knobs via *_override variables —
# locals below resolve preset → override → final effective value.
# =============================================================================

locals {
  # ---------------------------------------------------------------------------
  # Per-job caps — fixed across all presets. A single batch job can use up to
  # 62 vCPU / 500 GiB RAM. Sized to fit on n2d-highmem-64 (64 vCPU / 512 GiB)
  # after GKE daemonset overhead (~2 vCPU, ~12 GiB).
  # ---------------------------------------------------------------------------
  max_job_cpu       = 62
  max_job_memory_gi = 500

  # ---------------------------------------------------------------------------
  # Batch pool shapes — five pools mirroring AWS CloudFormation. Same
  # Kubernetes label (role=batch) and taint (dedicated=batch:NoSchedule) on
  # every pool so the K8s scheduler treats them uniformly. The GKE autoscaler
  # picks the smallest-fitting pool when a pending pod arrives — small jobs
  # land on small nodes, big jobs on big nodes. This avoids the wastage of
  # always running every pod on the largest machine type.
  # ---------------------------------------------------------------------------
  batch_pool_specs = {
    "16c-64g" = {
      machine_type = "n2d-standard-16"
      cpu          = 16
      memory_gi    = 64
      # AWS counterpart: m7i.4xlarge
    }
    "32c-128g" = {
      machine_type = "n2d-standard-32"
      cpu          = 32
      memory_gi    = 128
      # AWS counterpart: m7i.8xlarge
    }
    "64c-256g" = {
      machine_type = "n2d-standard-64"
      cpu          = 64
      memory_gi    = 256
      # AWS counterpart: m7i.16xlarge
    }
    "32c-256g" = {
      machine_type = "n2d-highmem-32"
      cpu          = 32
      memory_gi    = 256
      # AWS counterpart: r7i.8xlarge — memory-heavy 1c:8GiB ratio
    }
    "64c-512g" = {
      machine_type = "n2d-highmem-64"
      cpu          = 64
      memory_gi    = 512
      # AWS counterpart: r7i.16xlarge — largest pool, 1c:8GiB ratio
    }
  }

  # ---------------------------------------------------------------------------
  # Deployment-size presets. Per-batch-pool max-node values mirror AWS's
  # MaxBatch16c64g / MaxBatch32c128g / etc. exactly, so the same deployment_size
  # label gives the same parallelism on both clouds.
  # ---------------------------------------------------------------------------
  presets = {
    small = {
      # Small team / testing. ~10 batch nodes peak across all pool shapes;
      # supports 4 small + 2 medium + 1 large + 2 mem-heavy + 1 huge in
      # parallel (matching AWS small).
      ui_max_nodes = 4
      batch_pool_max_nodes = {
        "16c-64g"  = 4
        "32c-128g" = 2
        "64c-256g" = 1
        "32c-256g" = 2
        "64c-512g" = 1
      }
      filestore_capacity_gb    = 1024
      cpus_global_quota        = 512
      n2d_cpus_quota           = 512
      pd_ssd_quota_gb          = 2048
      filestore_zonal_quota_gb = 1024
      instances_quota          = 32
      in_use_addresses_quota   = 16
    }
    medium = {
      ui_max_nodes = 8
      batch_pool_max_nodes = {
        "16c-64g"  = 8
        "32c-128g" = 4
        "64c-256g" = 2
        "32c-256g" = 4
        "64c-512g" = 2
      }
      filestore_capacity_gb    = 2048
      cpus_global_quota        = 1024
      n2d_cpus_quota           = 1024
      pd_ssd_quota_gb          = 4096
      filestore_zonal_quota_gb = 2048
      instances_quota          = 48
      in_use_addresses_quota   = 16
    }
    large = {
      ui_max_nodes = 16
      batch_pool_max_nodes = {
        "16c-64g"  = 16
        "32c-128g" = 8
        "64c-256g" = 4
        "32c-256g" = 8
        "64c-512g" = 4
      }
      filestore_capacity_gb    = 4096
      cpus_global_quota        = 2048
      n2d_cpus_quota           = 2048
      pd_ssd_quota_gb          = 8192
      filestore_zonal_quota_gb = 4096
      instances_quota          = 64
      in_use_addresses_quota   = 24
    }
    xlarge = {
      # Heavy production. Quota requests at this size typically need human
      # review (24-72h).
      ui_max_nodes = 16
      batch_pool_max_nodes = {
        "16c-64g"  = 32
        "32c-128g" = 16
        "64c-256g" = 8
        "32c-256g" = 16
        "64c-512g" = 8
      }
      filestore_capacity_gb    = 8192
      cpus_global_quota        = 4096
      n2d_cpus_quota           = 4096
      pd_ssd_quota_gb          = 16384
      filestore_zonal_quota_gb = 8192
      instances_quota          = 128
      in_use_addresses_quota   = 32
    }
  }

  preset = local.presets[var.deployment_size]

  # ---------------------------------------------------------------------------
  # Resolved per-pool max-node count (preset → user override).
  # ---------------------------------------------------------------------------
  effective_batch_pool_max_nodes = {
    for pool_id, spec in local.batch_pool_specs :
    pool_id => coalesce(
      lookup(var.batch_pool_max_nodes_overrides, pool_id, null),
      local.preset.batch_pool_max_nodes[pool_id]
    )
  }

  # Total batch capacity at preset maxes — used to size Kueue ClusterQueue
  # and to size N2D quota auto-requests. This is the upper bound on what the
  # cluster can run simultaneously across all batch pool shapes.
  total_batch_cpu = sum([
    for pool_id, max_nodes in local.effective_batch_pool_max_nodes :
    max_nodes * local.batch_pool_specs[pool_id].cpu
  ])
  total_batch_memory_gi = sum([
    for pool_id, max_nodes in local.effective_batch_pool_max_nodes :
    max_nodes * local.batch_pool_specs[pool_id].memory_gi
  ])

  # Convenience: total parallelism for messaging and quota justifications.
  # Sum of per-pool max-nodes — actual concurrent jobs depends on shape mix.
  total_batch_max_nodes = sum([
    for _, max_nodes in local.effective_batch_pool_max_nodes : max_nodes
  ])

  # ---------------------------------------------------------------------------
  # Other resolved values.
  # ---------------------------------------------------------------------------
  effective_ui_pool_max_nodes     = coalesce(var.ui_pool_max_nodes, local.preset.ui_max_nodes)
  effective_workspace_capacity_gb = coalesce(var.workspace_capacity_gb, local.preset.filestore_capacity_gb)

  effective_kueue_max_job_cpu    = coalesce(var.kueue_max_job_cpu, local.max_job_cpu)
  effective_kueue_max_job_memory = coalesce(var.kueue_max_job_memory, "${local.max_job_memory_gi}Gi")

  # Kueue ClusterQueue total = sum of all batch pool capacities. Sized this
  # way so Kueue admits jobs as long as the cluster can physically run them
  # (admission gate matches scheduler reality, not a smaller artificial cap).
  effective_kueue_batch_queue_cpu    = coalesce(var.kueue_batch_queue_cpu, local.total_batch_cpu)
  effective_kueue_batch_queue_memory = coalesce(var.kueue_batch_queue_memory, "${local.total_batch_memory_gi}Gi")
}
