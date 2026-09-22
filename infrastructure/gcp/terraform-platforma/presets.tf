# =============================================================================
# Deployment size presets
# =============================================================================
# Single source of truth for size-driven defaults. The preset selected via
# var.deployment_size drives:
#   - Batch capacity envelope (cluster-wide CPU/memory ceiling for NAP)
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
  # SINGLE SOURCE OF TRUTH: MEASURED GKE allocatable per batch machine type.
  #
  # Read off real GKE 1.35 nodes with
  #   kubectl get node <n> -o jsonpath='{.status.allocatable.{cpu,memory}}'
  # (n2d-highmem-64 on pl-e2e-cluster; n2d-highmem-96 and n2-highmem-128 on
  # tmp-alloc-verify, europe-west3-a, 2026-09-21). Values are floor(measured):
  # 486.94 / 733.81 / 826.38 GiB. Do not add a row without booting the shape.
  #
  # The per-job ceiling is DERIVED from this table (floor - 2), so changing a
  # machine type moves the ceiling with it and they cannot drift apart.
  # floor(486.94) - 2 = 484 reproduces the long-standing n2d-highmem-64 ceiling
  # exactly, so this generalises the existing convention rather than changing it.
  #
  # NOTE the reserve model is cloud-specific: GKE uses a tiered percentage
  # formula (25/20/10/6/2% + eviction), EKS uses 255 MiB + 11 MiB * maxPods +
  # 100 MiB. Never derive one cloud's numbers from the other's.
  # ---------------------------------------------------------------------------
  batch_node_allocatable = {
    "n2d-highmem-64" = { cpu = 64, memory_gi = 486 }  # 512 GiB nominal
    "n2d-highmem-96" = { cpu = 96, memory_gi = 733 }  # 768 GiB nominal
    "n2-highmem-128" = { cpu = 128, memory_gi = 826 } # 864 GiB nominal
  }

  # Largest batch shape each deployment size is expected to land on. The
  # ComputeClass ladder (batch_machine_priorities) may offer smaller shapes too;
  # this names the ceiling-setting one.
  largest_batch_type = {
    small  = "n2d-highmem-64"
    medium = "n2d-highmem-96"
    large  = "n2d-highmem-96"
    xlarge = "n2-highmem-128"
  }

  # PARITY WITH AWS holds at small/medium only. AWS large is 733Gi
  # (r7i.24xlarge) vs GCP 731Gi, and AWS xlarge is 973Gi (r8i.32xlarge,
  # 1024 GiB nominal) vs GCP 824Gi -- GCP's largest N2 highmem shape is only
  # 864 GiB nominal. n2d-highmem stops at 96, and a 1 TiB+ GCP shape would mean
  # a memory-optimized (M*) or C4 family: a new <FAMILY>-CPUS quota request in
  # quotas.tf plus a PRESET_<FAMILY>_CPUS array in cloudshell/install.sh, and
  # much thinner zonal availability.
  # ---------------------------------------------------------------------------

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
  # (terraform-platforma/computeclass.tf). Ordered SMALLEST-FIRST: the
  # autoscaler picks the first entry whose machine fits the pending pod, so a
  # small job gets a small node, and a large job simply falls through every
  # tier it doesn't fit. Each tier lists n2d (AMD) first and n2 (Intel) as the
  # stockout fallback, so a zone running out of AMD capacity retries at the
  # SAME size before moving up to a bigger machine.
  #
  # Two memory:CPU ratios are interleaved. At each vCPU count the standard
  # shape (4 GiB/vCPU) comes BEFORE the highmem shape of the same vCPU count
  # (8 GiB/vCPU) -- e.g. n2d-standard-32 (32/128) ahead of n2d-highmem-32
  # (32/256). Measured batch requests run about 4.6-5.4 GiB per vCPU (e.g.
  # 16 vCPU / 73-87 GiB), so highmem supplies roughly twice the memory per core
  # these jobs ask for and CPU is what binds. First-fit therefore takes the
  # cheaper, more widely available standard shape whenever the pod actually
  # fits it; a pod needing more memory per core does not fit and falls through
  # to the highmem entry.
  #
  # Naming machine types explicitly is what makes batch work at all -- this is
  # exactly why bare cluster-wide NAP failed (it shapes within the E2 family
  # and never reaches for predefined highmem types).
  #
  # HOW THE SMALLEST SHAPE RELATES TO THE QUOTA PRESETS. Batch node count is
  # the Kueue envelope divided by whatever shapes the autoscaler actually
  # picks, and every node pins a 200 GiB pd-balanced boot disk, which counts
  # against SSD-TOTAL-GB. pd_ssd_quota_gb and instances_quota are therefore
  # sized against a REALISTIC shape mix -- an average batch node of >=32 vCPU:
  #   small   320/32 = 10 nodes x 200 GiB =  2000 GiB (quota  4096)
  #   medium  640/32 = 20 nodes x 200 GiB =  4000 GiB (quota  8192)
  #   large  1280/32 = 40 nodes x 200 GiB =  8000 GiB (quota 16384)
  #   xlarge 2560/32 = 80 nodes x 200 GiB = 16000 GiB (quota 32768)
  # i.e. roughly 2x headroom over the expected case, and unchanged from the
  # values these presets have always carried.
  #
  # This is DELIBERATELY not the theoretical worst case. Filling the whole
  # envelope with 8 vCPU nodes would need 4x these numbers (small: 40 nodes,
  # 8000 GiB), which is past the ~2x threshold where Google stops
  # auto-approving quota increases and sends them to human review -- a real
  # cost on every first install, to cover a mix the workload contradicts. On
  # the GSK production cluster the only batch pool the ComputeClass has ever
  # auto-created is n2d-highmem-64, and their measured job shape (16 vCPU /
  # 73-87 GiB) cannot fit an 8 vCPU node at all.
  #
  # The accepted trade-off: an unusual wave of very small jobs can exhaust
  # SSD-TOTAL-GB before the Kueue envelope is full, leaving admitted pods
  # Pending on a QUOTA_EXCEEDED scale-up while CPU quota still looks free. If
  # that ever shows up in the field, raise pd_ssd_quota_gb (and
  # instances_quota) rather than removing the small tiers -- and move the
  # PRESET_PD_SSD_GB / PRESET_INSTANCES arrays in cloudshell/install.sh in
  # lockstep, or the pre-flight quota check will disagree with reality.
  #
  # The xlarge tier is the fallback for when the large tier is exhausted in
  # every zone. Ported from the GSK production deployment, where on 2026-09-01
  # a large job stalled with no.scale.up.nap.pod.zonal.resources.exceeded in
  # all three zones and there was nothing above the large tier to fall back to.
  #
  # On-demand only (no spot). All entries are N2D or N2, so no GCP quota beyond
  # the N2D_CPUS / N2_CPUS already requested in quotas.tf. Adding a new family
  # needs a matching <FAMILY>-CPUS quota request in quotas.tf and a
  # PRESET_<FAMILY>_CPUS array in cloudshell/install.sh (recipe in a comment
  # there). NOTE: priorities are a fallback/availability list, not a per-pod
  # sizing menu -- once a large pool exists, the autoscaler bin-packs smaller
  # pods onto it rather than spinning up a separate small pool. That's fine
  # (efficient packing); true per-tier isolation would need separate
  # ComputeClasses + job routing, which isn't worth the complexity.
  #
  # Machine shapes verified against `gcloud compute machine-types list`
  # (europe-west3-a, 2026-09-16); memory figures below are GiB as GCE reports
  # them, allocatable is after GKE/kubelet reserve.
  batch_machine_priorities = [
    # --- 8 vCPU / 64 GiB (~52 GiB allocatable) -- smallest shape, see above ---
    "n2d-highmem-8",
    "n2-highmem-8",
    # --- 16 vCPU / 64 GiB (~52 GiB allocatable) ---
    "n2d-standard-16",
    "n2-standard-16",
    # --- 16 vCPU / 128 GiB (~108 GiB allocatable) ---
    "n2d-highmem-16",
    "n2-highmem-16",
    # --- 32 vCPU / 128 GiB (~108 GiB allocatable) ---
    "n2d-standard-32",
    "n2-standard-32",
    # --- 32 vCPU / 256 GiB (~225 GiB allocatable) ---
    "n2d-highmem-32",
    "n2-highmem-32",
    # --- 64 vCPU / 256 GiB (~225 GiB allocatable) ---
    "n2d-standard-64",
    "n2-standard-64",
    # --- 64 vCPU / 512 GiB: primary home of the max 62 vCPU / 484 GiB job.
    #     486.94 GiB allocatable MEASURED on a live n2d-highmem-64 ---
    "n2d-highmem-64",
    "n2-highmem-64",
    # --- xlarge tier: fallback when the large tier is stocked out in every
    #     zone. 80 vCPU / 640 GiB (~607 GiB alloc) ---
    "n2d-highmem-80",
    "n2-highmem-80",
    # --- 96 vCPU / 768 GiB (733.81 GiB allocatable, MEASURED) -- large ceiling ---
    "n2d-highmem-96",
    "n2-highmem-96",
    # --- 128 vCPU / 864 GiB (826.38 GiB allocatable, MEASURED) -- xlarge ceiling.
    #     NOTE this list is NOT preset-scoped: computeclass.tf applies it at
    #     every deployment_size, so small/medium can also land here if every
    #     smaller tier is stocked out in every zone. That is a last-resort
    #     fallback (first-fit walks the list in order), but it does mean a
    #     small GCP cluster can provision a 128 vCPU node -- its 320 vCPU Kueue
    #     quota admits one. Scope the list per size if that is unacceptable.
    #     N2 only: n2d-highmem stops at 96. Covered by the existing N2_CPUS
    #     quota request, so no new family quota is needed. ---
    "n2-highmem-128",
  ]

  # ---------------------------------------------------------------------------
  # GPU capacity envelope per preset. Sizes the Kueue GPU ClusterQueue
  # admission quota across BOTH GPU SKUs (L4 and RTX PRO 6000). Sized as
  #   L4_quota × max(g2-standard-*.vcpu/mem) + RTX_quota × max(g4-standard-*.vcpu/mem)
  # so the GCE regional GPU quotas are the binding constraint (not Kueue).
  # Max single-GPU shapes:
  #   L4:           g2-standard-32 → 32 vCPU /  128 GiB / 1 L4
  #   RTX PRO 6000: g4-standard-48 → 48 vCPU /  192 GiB / 1 RTX PRO 6000
  #
  # Per `small`: 8× L4 + 4× RTX → 12 GPUs, 8×32+4×48=448 vCPU,
  # 8×128+4×192=1792 GiB. GPU counts mirror gpu_l4_max_nodes_per_shape +
  # gpu_rtx_pro_6000_max_nodes_per_shape in terraform-infra/presets.tf —
  # each pool can scale to that many nodes; the admission cap here is
  # per-cluster, not per-pool.
  # ---------------------------------------------------------------------------
  gpu_capacity = {
    small  = { gpus = 12, cpu = 448, memory_gi = 1792 }
    medium = { gpus = 24, cpu = 896, memory_gi = 3584 }
    large  = { gpus = 48, cpu = 1792, memory_gi = 7168 }
    xlarge = { gpus = 96, cpu = 3584, memory_gi = 14336 }
  }

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

  # Per-job ceiling DERIVED from the largest batch node's MEASURED allocatable.
  largest_batch_node        = local.batch_node_allocatable[local.largest_batch_type[var.deployment_size]]
  largest_batch_node_cpu    = local.largest_batch_node.cpu
  largest_batch_node_mem_gi = local.largest_batch_node.memory_gi

  max_job_cpu       = local.largest_batch_node_cpu - 2
  max_job_memory_gi = local.largest_batch_node_mem_gi - 2

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

  # Kueue GPU ClusterQueue admission cap. Consumed by kueue.dedicated.resources.gpu
  # in app.tf only when var.enable_gpu = true; otherwise the values are unused.
  effective_kueue_gpu_queue_cpu    = coalesce(var.kueue_gpu_queue_cpu, local.gpu_capacity[var.deployment_size].cpu)
  effective_kueue_gpu_queue_memory = coalesce(var.kueue_gpu_queue_memory, "${local.gpu_capacity[var.deployment_size].memory_gi}Gi")
  effective_kueue_gpu_queue_count  = coalesce(var.kueue_gpu_queue_count, local.gpu_capacity[var.deployment_size].gpus)

  # Per-GPU-job ceilings (kueue.maxJobResources.gpuCpu/gpuRam/gpuMemory). Set by
  # install.sh from the largest GPU node actually provisioned. Fallback (bare
  # terraform, no install.sh discovery) assumes the largest default shape,
  # g4-standard-48: 48 vCPU − 2 headroom = 46; GKE-allocatable RAM ≈ 168 GiB;
  # RTX PRO 6000 per-GPU VRAM = 96 GiB. In an RTX-less region the install.sh
  # value is authoritative (this default is only for the no-discovery path).
  effective_gpu_max_job_cpu    = coalesce(var.gpu_max_job_cpu, 46)
  effective_gpu_max_job_ram    = coalesce(var.gpu_max_job_ram, "168Gi")
  effective_gpu_max_job_memory = coalesce(var.gpu_max_job_memory, "96Gi")
}
