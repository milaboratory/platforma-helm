# =============================================================================
# Deployment-size presets — Kueue ClusterQueue quotas
# =============================================================================
# The Kueue-relevant slice of the CF DeploymentSize map (FindInMap
# [DeploymentSize, <size>, ...]). infra has its own copy for node-group
# MaxSize; the two modules are independent, so the size matrix is duplicated.
# Keep both in sync when changing sizing.
#
#   * max_job_*   — largest single job Kueue admits (constant across sizes; one
#                   batch node's allocatable). Mirrors kueue.maxJobResources.
#   * batch/ui_*  — total ClusterQueue quota per pool (kueue.dedicated.resources).
#                   UI quota is fixed at 64 vCPU / 256 GiB across all sizes.
#   * gpu_queue_gpu — GPU-job concurrency (nvidia.com/gpu ClusterQueue quota). The
#                   chart DERIVES the GPU flavor cpu/memory quota from this count
#                   times max_job_gpu_cpu/max_job_gpu_ram_gi, so those cpu/memory
#                   quotas are no longer set here (they were the drift source).
# =============================================================================

locals {
  max_job_cpu       = 62
  max_job_memory_gi = 484

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
      batch_cpu       = 252
      batch_memory_gi = 968
      ui_cpu          = 64
      ui_memory_gi    = 256
    }
    large = {
      batch_cpu       = 504
      batch_memory_gi = 1936
      ui_cpu          = 64
      ui_memory_gi    = 256
    }
    xlarge = {
      batch_cpu       = 1008
      batch_memory_gi = 3872
      ui_cpu          = 64
      ui_memory_gi    = 256
    }
  }

  preset = local.deployment_sizes[var.deployment_size]
}
