# =============================================================================
# Deployment size presets
# =============================================================================
# Verbatim transcription of the CloudFormation DeploymentSize mapping
# (cloudformation-eks-1-35.yaml). Single source of truth for size-driven
# defaults; var.deployment_size selects one preset.
#
# This module uses:
#   - max_ui / max_batch_* / max_gpu_*  → node group MaxSize per pool
# The platforma module's presets.tf carries the same table and uses:
#   - batch_cpu / batch_memory_gi / ui_cpu / ui_memory_gi → Kueue ClusterQueue quotas
#
# Both files MUST stay in sync. Keeping a copy in each module (rather than a
# shared module) preserves the "two independent root modules" property: each
# can be planned/applied on its own.
#
# Per-job ceiling is fixed across all sizes: 62 vCPU / 484Gi (r7i.16xlarge EKS
# allocatable minus DaemonSet overhead + safety margin). Matches the GCP
# n2d-highmem-64 ceiling so the same size label means the same capacity on both
# clouds.
# =============================================================================

locals {
  max_job_cpu       = 62
  max_job_memory_gi = 484

  deployment_sizes = {
    small = {
      batch_cpu         = 126
      batch_memory_gi   = 484
      ui_cpu            = 64
      ui_memory_gi      = 256
      max_batch_16c64g  = 4
      max_batch_32c128g = 2
      max_batch_64c256g = 1
      max_batch_32c256g = 2
      max_batch_64c512g = 1
      max_gpu_3g        = 2
      max_gpu_6g        = 2
      max_gpu_12g       = 1
      max_gpu_24g       = 1
      max_gpu_48g       = 1
      max_gpu_96g       = 1
      max_ui            = 4
    }
    medium = {
      batch_cpu         = 252
      batch_memory_gi   = 968
      ui_cpu            = 64
      ui_memory_gi      = 256
      max_batch_16c64g  = 8
      max_batch_32c128g = 4
      max_batch_64c256g = 2
      max_batch_32c256g = 4
      max_batch_64c512g = 2
      max_gpu_3g        = 4
      max_gpu_6g        = 3
      max_gpu_12g       = 2
      max_gpu_24g       = 2
      max_gpu_48g       = 2
      max_gpu_96g       = 1
      max_ui            = 8
    }
    large = {
      batch_cpu         = 504
      batch_memory_gi   = 1936
      ui_cpu            = 64
      ui_memory_gi      = 256
      max_batch_16c64g  = 16
      max_batch_32c128g = 8
      max_batch_64c256g = 4
      max_batch_32c256g = 8
      max_batch_64c512g = 4
      max_gpu_3g        = 8
      max_gpu_6g        = 6
      max_gpu_12g       = 4
      max_gpu_24g       = 4
      max_gpu_48g       = 4
      max_gpu_96g       = 2
      max_ui            = 16
    }
    xlarge = {
      batch_cpu         = 1008
      batch_memory_gi   = 3872
      ui_cpu            = 64
      ui_memory_gi      = 256
      max_batch_16c64g  = 32
      max_batch_32c128g = 16
      max_batch_64c256g = 8
      max_batch_32c256g = 16
      max_batch_64c512g = 8
      max_gpu_3g        = 16
      max_gpu_6g        = 12
      max_gpu_12g       = 8
      max_gpu_24g       = 8
      max_gpu_48g       = 8
      max_gpu_96g       = 4
      max_ui            = 16
    }
  }

  preset = local.deployment_sizes[var.deployment_size]
}
