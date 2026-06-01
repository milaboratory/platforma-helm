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
