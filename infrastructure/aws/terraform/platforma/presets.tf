# =============================================================================
# Deployment-size presets — Kueue ClusterQueue quotas
# =============================================================================
# The Kueue-relevant slice of the CF DeploymentSize map (FindInMap
# [DeploymentSize, <size>, ...]). infra has its own copy for node-group
# MaxSize; the two modules are independent, so the size matrix is duplicated.
# Keep both in sync when changing sizing.
#
#   * max_job_*   — largest single job Kueue admits (PRESET-DRIVEN since
#                   MILAB-6982; one batch node's allocatable). Mirrors
#                   kueue.maxJobResources. small 62/484 (r7i.16xlarge), medium/large 94/733 (r7i.24xlarge),
#                   large 94/733 (r7i.24xlarge), xlarge 126/973 (r8i.32xlarge).
#                   All MEASURED on real nodes -- see infra/presets.tf.
#                   Derivation + the "derived, not measured" caveat live in
#                   infra/presets.tf — keep both in sync.
#   * batch/ui_*  — total ClusterQueue quota per pool (kueue.dedicated.resources).
#                   UI quota is fixed at 64 vCPU / 256 GiB across all sizes.
#   * gpu_queue_gpu — GPU-job concurrency (nvidia.com/gpu ClusterQueue quota). The
#                   chart DERIVES the GPU flavor cpu/memory quota from this count
#                   times max_job_gpu_cpu/max_job_gpu_ram_gi, so those cpu/memory
#                   quotas are no longer set here (they were the drift source).
# =============================================================================

locals {
  # Per-job GPU ceilings. Mirror the largest GPU node group in infra/nodegroups.tf
  # GPU jobs run on a separate node pool, so a job needing a GPU is ceiled to these
  # instead of the batch max_job_cpu/max_job_memory_gi. CPU/RAM must be the largest
  # node's *allocatable* (capacity minus kubelet kube-reserved + eviction), not raw
  # capacity — a job clamped to capacity passes Kueue admission but its pod never
  # schedules and sits Pending. For g6e.12xlarge (384Gi capacity), EKS's tiered
  # kube-reserved (~4% at this size) + 100Mi eviction leaves ~369Gi allocatable.
  # CPU already carries headroom (48 physical -> 46). Keep in sync with the CF
  # resolver's _eks_alloc_ram_gib formula in cloudformation-eks-1-35.yaml.
  # Required when var.enable_gpu = true; unused otherwise.
  max_job_gpu_memory_gi = 48
  max_job_gpu_cpu       = 46
  max_job_gpu_ram_gi    = 369

  # GPU-job concurrency. The chart derives the GPU flavor cpu/memory quota from this
  # count times max_job_gpu_cpu/max_job_gpu_ram_gi, so the flavor quota can never be
  # smaller than a correctly-ceiled GPU job. Only the count is set here.
  gpu_queue_gpu = 8

  deployment_sizes = {
    small = {
      batch_cpu       = 126
      batch_memory_gi = 484
      ui_cpu          = 64
      ui_memory_gi    = 256
    }
    medium = {
      batch_cpu       = 346
      batch_memory_gi = 1701
      ui_cpu          = 64
      ui_memory_gi    = 256
    }
    large = {
      batch_cpu       = 692
      batch_memory_gi = 3402
      ui_cpu          = 64
      ui_memory_gi    = 256
    }
    xlarge = {
      batch_cpu       = 1636
      batch_memory_gi = 8750
      ui_cpu          = 64
      ui_memory_gi    = 256
    }
  }

  preset = local.deployment_sizes[var.deployment_size]

  # Per-job ceiling DERIVED from the largest batch node's MEASURED allocatable
  # (floor - 2). Mirrors infra/presets.tf -- keep the two tables in sync.
  batch_node_allocatable = {
    "r7i.16xlarge" = { cpu = 64, memory_gi = 486 }
    "r7i.24xlarge" = { cpu = 96, memory_gi = 735 }
    "r8i.32xlarge" = { cpu = 128, memory_gi = 975 }
  }
  largest_batch_type = {
    small  = "r7i.16xlarge"
    medium = "r7i.24xlarge"
    large  = "r7i.24xlarge"
    xlarge = "r8i.32xlarge"
  }
  largest_batch_node        = local.batch_node_allocatable[local.largest_batch_type[var.deployment_size]]
  largest_batch_node_cpu    = local.largest_batch_node.cpu
  largest_batch_node_mem_gi = local.largest_batch_node.memory_gi

  max_job_cpu       = local.largest_batch_node_cpu - 2
  max_job_memory_gi = local.largest_batch_node_mem_gi - 2
}
