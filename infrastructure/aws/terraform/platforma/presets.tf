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
#   * gpu_*       — GPU ClusterQueue quota (constant; mirrors CF's hardcoded
#                   kueue.dedicated.resources.gpu = { gpu: 8, cpu: 32, mem: 128Gi }).
# =============================================================================

locals {
  max_job_cpu       = 62
  max_job_memory_gi = 484

  # Per-job GPU ceilings. Mirror the largest GPU node group in infra/nodegroups.tf
  # GPU jobs run on a separate node pool, so a job needing a GPU is ceiled to these
  # instead of the batch max_job_cpu/max_job_memory_gi. CPU/RAM use the largest node's
  # allocatable (headroom for kubelet + DaemonSets), matching the batch convention.
  # Required when var.enable_gpu = true; unused otherwise.
  max_job_gpu_memory_gi = 48
  max_job_gpu_cpu       = 46
  max_job_gpu_ram_gi    = 384

  gpu_queue_gpu       = 8
  gpu_queue_cpu       = 32
  gpu_queue_memory_gi = 128

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
