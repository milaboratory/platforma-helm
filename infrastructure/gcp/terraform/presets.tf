# =============================================================================
# Deployment size presets
# =============================================================================
# Single source of truth for size-driven defaults. The preset selected via
# var.deployment_size drives:
#   - Batch capacity envelope (sizes the Kueue ClusterQueue admission quota)
#   - UI pool max size (static pool — see google_container_node_pool.ui)
#   - Kueue ClusterQueue quotas (computed from batch_capacity)
#   - Filestore capacity
#   - Automated quota requests (CPUS_ALL_REGIONS, N2D_CPUS, N2_CPUS, PD SSD, Filestore)
#
# Per-preset envelope mirrors the AWS CloudFormation parallelism table so the
# same label (small/medium/large/xlarge) means the same workload capacity on
# both clouds.
#
# Power users can override individual knobs via *_override variables —
# locals below resolve preset → override → final effective value.
# =============================================================================

locals {
  # ---------------------------------------------------------------------------
  # Per-job caps — fixed across all presets. A single batch job can use up to
  # 62 vCPU / 484 GiB RAM. Derived from measured GKE allocatable on
  # n2d-highmem-64 (486.94 GiB) minus GKE-managed DaemonSet overhead (~1 GiB)
  # minus 1 GiB safety margin for user-installed DaemonSets. (The previous
  # 500 GiB cap could never actually schedule — a 485-500 GiB job hung pending
  # forever because no highmem-64 node has that much allocatable.)
  # ---------------------------------------------------------------------------
  max_job_cpu       = 62
  max_job_memory_gi = 484

  # ---------------------------------------------------------------------------
  # Batch capacity envelope per preset. Batch nodes are provisioned on demand
  # by the ComputeClass (computeclass.tf), so they're no longer fixed-shape
  # static pools. These values size the Kueue ClusterQueue admission quota —
  # the real cap on concurrent batch work (the ComputeClass could create more
  # pools, but Kueue won't admit beyond this).
  #
  # Values mirror the SUM of the previous static 5-pool layout's max
  # capacities (n2d-standard-16/32/64 + n2d-highmem-32/64), using measured
  # allocatable per node:
  #   small:  4*16 + 2*32 + 1*64 + 2*32 + 1*64       = 320 vCPU
  #           4*55 + 2*114 + 1*237 + 2*238 + 1*484   = 1645 GiB
  #   medium: 2x small = 640 vCPU / 3290 GiB
  #   large:  4x small = 1280 vCPU / 6580 GiB
  #   xlarge: 8x small = 2560 vCPU / 13160 GiB
  # ---------------------------------------------------------------------------
  batch_capacity = {
    small  = { cpu = 320, memory_gi = 1645 }
    medium = { cpu = 640, memory_gi = 3290 }
    large  = { cpu = 1280, memory_gi = 6580 }
    xlarge = { cpu = 2560, memory_gi = 13160 }
  }

  # ---------------------------------------------------------------------------
  # Batch machine-type priority list for the ComputeClass (computeclass.tf).
  # Listed in fallback order — the autoscaler tries the first; on
  # stockout/unavailability (ZONE_RESOURCE_POOL_EXHAUSTED) it skips to the
  # next. ALL entries are highmem (8 GiB/vCPU) because batch jobs run a high
  # memory:CPU ratio (e.g. 62 vCPU / 484 GiB ≈ 7.8 GiB/vCPU) that the default
  # E2/standard families cannot express — this is exactly why bare
  # cluster-wide NAP failed (it shapes within E2 and never reaches for
  # predefined highmem types), and why we name the machine types explicitly
  # via a ComputeClass.
  #
  # On-demand only (no spot). Each family needs a matching N<FAMILY>-CPUS
  # quota in quotas.tf and a PRESET_*_CPUS array in cloudshell/install.sh.
  # To extend (c3-highmem, etc.): append here + add quota + add bash array.
  # Size tiers (small → large) let the autoscaler use a smaller machine when
  # only small jobs are pending; large jobs skip the tiers they don't fit. The
  # largest n2d entry then falls back to n2 (Intel) on n2d (AMD) stockout, then
  # to standard-128 as a last resort. NOTE: priorities are a fallback list, not
  # a per-pod sizing menu — once a large pool exists the autoscaler bin-packs
  # smaller pods onto it. n2d + n2 families only (C3/C3D deferred), so no new
  # GCP quota beyond N2D_CPUS / N2_CPUS.
  batch_machine_priorities = [
    "n2d-highmem-16",   # 16 vCPU / 128 GiB  (N2D)
    "n2d-highmem-32",   # 32 vCPU / 256 GiB  (N2D)
    "n2d-highmem-48",   # 48 vCPU / 384 GiB  (N2D)
    "n2d-highmem-64",   # 64 vCPU / 512 GiB  (N2D) — primary for the max 62/484 job
    "n2-highmem-64",    # 64 vCPU / 512 GiB  (N2, Intel) — fallback on n2d stockout
    "n2d-standard-128", # 128 vCPU / 512 GiB (N2D) — last resort
    "n2-standard-128",  # 128 vCPU / 512 GiB (N2)  — last resort
  ]

  # ---------------------------------------------------------------------------
  # Batch ZONE fallback tiers for the ComputeClass (computeclass.tf). Ordered
  # sets of zones the class prefers, from most to least preferred:
  #   tier 1 = [local.zone]           — the ZONAL Filestore zone; preferred so
  #                                     batch NFS traffic stays in-zone (no
  #                                     cross-zone egress).
  #   tier 2 = batch_fallback_zones   — spilled to only when tier 1 is
  #                                     capacity-exhausted; incurs cross-zone
  #                                     Filestore egress.
  # The full machine-family ladder (batch_machine_priorities) is expanded within
  # EACH tier (computeclass.tf), so GKE exhausts every family in the Filestore
  # zone before spilling to another zone. activeMigration.optimizeRulePriority
  # (already on) then migrates batch back to tier 1 when its capacity returns.
  # Empty fallback list => tier 1 only (single-zone, original behaviour). The
  # primary zone is filtered out of the fallback set to avoid a duplicate tier.
  # ---------------------------------------------------------------------------
  batch_fallback_zones = [
    for s in var.batch_fallback_zone_suffixes : "${var.region}-${s}"
    if s != var.zone_suffix
  ]
  batch_priority_zone_tiers = concat(
    [[local.zone]],
    length(local.batch_fallback_zones) > 0 ? [local.batch_fallback_zones] : [],
  )

  # ---------------------------------------------------------------------------
  # Deployment-size presets. Per-preset values mirror AWS CloudFormation
  # so the same label gives the same parallelism on both clouds.
  #
  # pd_ssd doubled vs the pre-ComputeClass defaults because ComputeClass-
  # managed batch nodes use 200 GiB root disks (computeclass.tf) instead of
  # the previous static pools' 100 GiB. Headroom included for system + UI
  # pools sharing the same regional SSD quota.
  # ---------------------------------------------------------------------------
  presets = {
    small = {
      # Small team / testing. ~10 batch nodes peak (mixed shapes); supports
      # roughly 4 small + 2 medium + 1 large + 2 mem-heavy + 1 huge jobs in
      # parallel (matching AWS small).
      ui_max_nodes             = 4
      filestore_capacity_gb    = 1024
      cpus_global_quota        = 512
      n2d_cpus_quota           = 512
      n2_cpus_quota            = 512
      pd_ssd_quota_gb          = 4096
      filestore_zonal_quota_gb = 1024
      instances_quota          = 32
      in_use_addresses_quota   = 16
    }
    medium = {
      ui_max_nodes             = 8
      filestore_capacity_gb    = 2048
      cpus_global_quota        = 1024
      n2d_cpus_quota           = 1024
      n2_cpus_quota            = 1024
      pd_ssd_quota_gb          = 8192
      filestore_zonal_quota_gb = 2048
      instances_quota          = 48
      in_use_addresses_quota   = 16
    }
    large = {
      ui_max_nodes             = 16
      filestore_capacity_gb    = 4096
      cpus_global_quota        = 2048
      n2d_cpus_quota           = 2048
      n2_cpus_quota            = 2048
      pd_ssd_quota_gb          = 16384
      filestore_zonal_quota_gb = 4096
      instances_quota          = 64
      in_use_addresses_quota   = 24
    }
    xlarge = {
      # Heavy production. Quota requests at this size typically need human
      # review (24-72h).
      ui_max_nodes             = 16
      filestore_capacity_gb    = 8192
      cpus_global_quota        = 4096
      n2d_cpus_quota           = 4096
      n2_cpus_quota            = 4096
      pd_ssd_quota_gb          = 32768
      filestore_zonal_quota_gb = 8192
      instances_quota          = 128
      in_use_addresses_quota   = 32
    }
  }

  preset = local.presets[var.deployment_size]

  # ---------------------------------------------------------------------------
  # Resolved batch capacity. Sizes the Kueue ClusterQueue admission quota
  # (app.tf). This is the real cap on concurrent batch work — the ComputeClass
  # provisions nodes on demand, but Kueue won't admit more than this regardless
  # of how many pools the ComputeClass could create.
  # ---------------------------------------------------------------------------
  total_batch_cpu       = local.batch_capacity[var.deployment_size].cpu
  total_batch_memory_gi = local.batch_capacity[var.deployment_size].memory_gi

  # ---------------------------------------------------------------------------
  # Other resolved values.
  # ---------------------------------------------------------------------------
  effective_ui_pool_max_nodes     = coalesce(var.ui_pool_max_nodes, local.preset.ui_max_nodes)
  effective_workspace_capacity_gb = coalesce(var.workspace_capacity_gb, local.preset.filestore_capacity_gb)

  effective_kueue_max_job_cpu    = coalesce(var.kueue_max_job_cpu, local.max_job_cpu)
  effective_kueue_max_job_memory = coalesce(var.kueue_max_job_memory, "${local.max_job_memory_gi}Gi")

  # Kueue ClusterQueue total = batch capacity envelope — the admission cap.
  effective_kueue_batch_queue_cpu    = coalesce(var.kueue_batch_queue_cpu, local.total_batch_cpu)
  effective_kueue_batch_queue_memory = coalesce(var.kueue_batch_queue_memory, "${local.total_batch_memory_gi}Gi")
}
