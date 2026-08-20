# =============================================================================
# Deployment size presets
# =============================================================================
# Single source of truth for size-driven defaults. The preset selected via
# var.deployment_size drives:
#   - Batch capacity envelope (cluster-wide CPU/memory ceiling for NAP)
#   - UI pool max size (static pool — see google_container_node_pool.ui)
#   - Kueue ClusterQueue quotas (computed from batch_capacity)
#   - Filestore capacity
#   - Automated quota requests (CPUS_ALL_REGIONS, N2D_CPUS, N2_CPUS, PD SSD,
#     Filestore, and — when enable_gpu — NVIDIA_L4_GPUS / NVIDIA_RTX_PRO_6000_GPUS)
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
  # n2d-highmem-64 (486.94 GiB on pl-e2e-cluster) minus GKE-managed DaemonSet
  # overhead (~1 GiB: fluentbit-gke, gke-metrics-agent, anetd, netd,
  # pdcsi-node, node-local-dns, gke-metadata-server, filestore-node, gmp
  # collector) minus 1 GiB safety margin for user-installed DaemonSets.
  # ---------------------------------------------------------------------------
  max_job_cpu       = 62
  max_job_memory_gi = 484

  # ---------------------------------------------------------------------------
  # Batch capacity envelope per preset. Batch nodes are provisioned on demand
  # by the ComputeClass (terraform-platforma/computeclass.tf), so they're no
  # longer fixed-shape static pools. These values size the Kueue ClusterQueue
  # admission quota — the real cap on concurrent batch work (the ComputeClass
  # could create more pools, but Kueue won't admit beyond this).
  #
  # Values mirror the SUM of the previous static 5-pool layout's max
  # capacities (n2d-standard-16/32/64 + n2d-highmem-32/64). Note that on
  # AWS the equivalent CloudFormation BatchMemoryGi value is smaller —
  # AWS conservatively sizes its Kueue ClusterQueue at "fits-on-largest-
  # node × max_count" because Kueue's per-job ceiling has to fit on a
  # single node. GCP's NAP envelope is the physical capacity ceiling
  # (what the cluster can actually run), which is wider. Kueue admission
  # ceiling is still derived from this same envelope on both clouds, but
  # the GCP value matches physical capacity 1:1 whereas AWS undersizes.
  # Same deployment_size therefore means similar (not identical)
  # workload capacity on both clouds.
  #
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

  # Batch machine-type priority list for the ComputeClass
  # (terraform-platforma/computeclass.tf). Listed in fallback order — the
  # autoscaler tries the first; on stockout/unavailability it falls back to
  # the next. ALL entries are highmem (8 GiB/vCPU) because batch jobs run a
  # high memory:CPU ratio (e.g. 62 vCPU / 484 GiB ≈ 7.8 GiB/vCPU) that the
  # default E2/standard families cannot express — this is exactly why bare
  # cluster-wide NAP failed (it shapes within E2 and never reaches for
  # predefined highmem types), and why we must name the machine types
  # explicitly via a ComputeClass.
  #
  # On-demand only (no spot). Each family needs a matching N<FAMILY>-CPUS
  # quota in quotas.tf and PRESET_*_CPUS array in cloudshell/install.sh.
  # To extend (c3-highmem, etc.): append here + add quota + add bash array.
  # Size tiers (small → large) let the autoscaler use a smaller machine when
  # only small jobs are pending (no large pool exists yet); large jobs skip
  # the tiers they don't fit. The largest n2d entry then falls back to n2 on
  # n2d stockout. NOTE: priorities are a fallback/availability list, not a
  # per-pod sizing menu — once a large pool exists, the autoscaler bin-packs
  # smaller pods onto it rather than spinning up a separate small pool. That's
  # fine (efficient packing); true per-tier isolation would need separate
  # ComputeClasses + job routing, which isn't worth the complexity here.
  # n2d + n2 families only (C3/C3D deferred pending team verification). Size
  # tiers first; then n2 highmem fallback; then standard-128 as a last-resort
  # (high core count machine that still fits a 484 GiB job if every highmem-64
  # is stocked out). All entries are N2D or N2 family, so no new GCP quota
  # beyond the N2D_CPUS / N2_CPUS already requested in quotas.tf.
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
  # Deployment-size presets. Per-preset values mirror AWS CloudFormation
  # so the same label gives the same parallelism on both clouds.
  # ---------------------------------------------------------------------------
  presets = {
    small = {
      # Small team / testing. ~10 batch nodes peak (mixed shapes); supports
      # roughly 4 small + 2 medium + 1 large + 2 mem-heavy + 1 huge jobs in
      # parallel (matching AWS small).
      # pd_ssd doubled vs pre-NAP defaults (~2048 → 4096) because NAP-managed
      # batch nodes use 200 GiB root disks (var.batch_pool_disk_size_gb)
      # instead of the previous static pools' 100 GiB. Headroom included
      # for system + UI pools sharing the same regional SSD quota.
      #
      # gpu_l4_max_nodes_per_shape: each of the 5 g2-standard-* pools
      # autoscales 0..N. Total L4 ceiling = 5 × N. With N=8 a `small`
      # cluster could in theory create 40 L4 nodes; in practice the GCE
      # NVIDIA_L4_GPUS regional quota is the binding constraint (auto-requested
      # by quotas.tf when enable_gpu, at this per-shape value). Sized as a
      # per-shape ceiling so any one shape alone can absorb a wave of small or
      # mixed-RAM jobs.
      #
      # gpu_rtx_pro_6000_max_nodes_per_shape: same model for the 4
      # g4-standard-* pools (each 1× RTX PRO 6000). Sized lower than L4
      # since RTX PRO 6000 is a smaller GCE inventory tier and a higher
      # per-node cost — most workloads should land on L4 unless they need
      # >24 GiB VRAM or Blackwell-class FP8/FP4. Bound by NVIDIA_RTX_PRO_6000_GPUS
      # regional quota (auto-requested by quotas.tf when enable_gpu, like L4).
      ui_max_nodes                         = 4
      filestore_capacity_gb                = 1024
      cpus_global_quota                    = 512
      n2d_cpus_quota                       = 512
      n2_cpus_quota                        = 512
      pd_ssd_quota_gb                      = 4096
      filestore_zonal_quota_gb             = 1024
      instances_quota                      = 32
      in_use_addresses_quota               = 16
      gpu_l4_max_nodes_per_shape           = 8
      gpu_rtx_pro_6000_max_nodes_per_shape = 4
    }
    medium = {
      ui_max_nodes                         = 8
      filestore_capacity_gb                = 2048
      cpus_global_quota                    = 1024
      n2d_cpus_quota                       = 1024
      n2_cpus_quota                        = 1024
      pd_ssd_quota_gb                      = 8192
      filestore_zonal_quota_gb             = 2048
      instances_quota                      = 48
      in_use_addresses_quota               = 16
      gpu_l4_max_nodes_per_shape           = 16
      gpu_rtx_pro_6000_max_nodes_per_shape = 8
    }
    large = {
      ui_max_nodes                         = 16
      filestore_capacity_gb                = 4096
      cpus_global_quota                    = 2048
      n2d_cpus_quota                       = 2048
      n2_cpus_quota                        = 2048
      pd_ssd_quota_gb                      = 16384
      filestore_zonal_quota_gb             = 4096
      instances_quota                      = 64
      in_use_addresses_quota               = 24
      gpu_l4_max_nodes_per_shape           = 32
      gpu_rtx_pro_6000_max_nodes_per_shape = 16
    }
    xlarge = {
      # Heavy production. Quota requests at this size typically need human
      # review (24-72h).
      ui_max_nodes                         = 16
      filestore_capacity_gb                = 8192
      cpus_global_quota                    = 4096
      n2d_cpus_quota                       = 4096
      n2_cpus_quota                        = 4096
      pd_ssd_quota_gb                      = 32768
      filestore_zonal_quota_gb             = 8192
      instances_quota                      = 128
      in_use_addresses_quota               = 32
      gpu_l4_max_nodes_per_shape           = 64
      gpu_rtx_pro_6000_max_nodes_per_shape = 32
    }
  }

  preset = local.presets[var.deployment_size]

  # ---------------------------------------------------------------------------
  # Resolved batch capacity. Sizes the Kueue ClusterQueue admission quota
  # (terraform-platforma/app.tf). This is the real cap on concurrent batch
  # work — the ComputeClass provisions nodes on demand, but Kueue won't admit
  # more than this regardless of how many pools the ComputeClass could create.
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

  # GPU L4 per-shape autoscaling ceiling. Each of the 5 g2-standard-*
  # static pools in gke.tf autoscales 0..effective_gpu_l4_max_nodes_per_shape.
  effective_gpu_l4_max_nodes_per_shape = local.preset.gpu_l4_max_nodes_per_shape

  # GPU RTX PRO 6000 per-shape autoscaling ceiling. Each of the 4 g4-standard-*
  # static pools in gke.tf autoscales 0..effective_gpu_rtx_pro_6000_max_nodes_per_shape.
  # Sized lower than L4 by default because RTX PRO 6000 is a smaller GCE
  # inventory tier and a higher per-node cost; operator can raise per-cluster.
  effective_gpu_rtx_pro_6000_max_nodes_per_shape = local.preset.gpu_rtx_pro_6000_max_nodes_per_shape

  # GPU pools — per-shape zone map ({shape = [zones]}) populated by install.sh
  # at deploy time via gcptest.sh discover (in this directory; runs locally
  # where gcloud is available). For each SKU, discover returns only the shapes
  # var.region actually offers, each mapped to the zones offering it; gke.tf
  # creates one node pool per entry (adaptive ladder — missing shapes absent).
  #
  # Multi-zone per shape gives GPU scale-ups capacity diversity: GCE inventory
  # varies independently per zone, so spreading maximises the chance any one
  # ProvisioningRequest finds stock.
  #
  # Per-SKU resolution, three cases:
  #   null      => bare `terraform apply` (no install.sh): fall back to the full
  #                default ladder in [local.zone]. Preserves pre-adaptive Tier-3.
  #   {}        => install.sh ran gcptest.sh discover and the SKU is NOT offered
  #                in var.region: empty map, and gpu_*_enabled below turns that
  #                SKU's pools off.
  #   {s=[z..]} => discovered per-shape zones for the SKU.
  #
  # Default ladders are the fallback for the null case only — they MUST mirror
  # the L4_LADDER / RTX_LADDER in gcptest.sh.
  default_gpu_l4_ladder           = ["g2-standard-4", "g2-standard-8", "g2-standard-12", "g2-standard-16", "g2-standard-32"]
  default_gpu_rtx_pro_6000_ladder = ["g4-standard-6", "g4-standard-12", "g4-standard-24", "g4-standard-48"]

  effective_gpu_l4_pools           = var.gpu_l4_pools == null ? { for s in local.default_gpu_l4_ladder : s => [local.zone] } : var.gpu_l4_pools
  effective_gpu_rtx_pro_6000_pools = var.gpu_rtx_pro_6000_pools == null ? { for s in local.default_gpu_rtx_pro_6000_ladder : s => [local.zone] } : var.gpu_rtx_pro_6000_pools

  # A SKU's pools are created only when GPU is on AND the SKU has at least one
  # usable shape. Lets a region with only one SKU (e.g. europe-north1 carries
  # RTX PRO 6000 but not L4) come up with just that SKU's pools.
  gpu_l4_enabled           = var.enable_gpu && length(local.effective_gpu_l4_pools) > 0
  gpu_rtx_pro_6000_enabled = var.enable_gpu && length(local.effective_gpu_rtx_pro_6000_pools) > 0

  # Whether to submit each SKU's GPU quota-increase request — decoupled from
  # pool creation so install.sh can request the increase while running that SKU
  # GPU-less (quota still below the deployment's need). null (bare terraform)
  # follows var.enable_gpu, preserving the pre-adaptive behaviour.
  effective_request_gpu_l4_quota           = var.request_gpu_l4_quota == null ? var.enable_gpu : var.request_gpu_l4_quota
  effective_request_gpu_rtx_pro_6000_quota = var.request_gpu_rtx_pro_6000_quota == null ? var.enable_gpu : var.request_gpu_rtx_pro_6000_quota
}
