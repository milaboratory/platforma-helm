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
# Per-job ceiling is PRESET-DRIVEN (MILAB-6982). small/medium keep the
# r7i.16xlarge ceiling (62 vCPU / 484Gi); large/xlarge unlock the bigger batch
# node groups:
#
#   size    per-job cap      backing node    nominal   EKS allocatable
#   small   62 vCPU / 484Gi  r7i.16xlarge    512 GiB   486.94 GiB (measured)
#   medium  94 vCPU / 733Gi  r7i.24xlarge    768 GiB   735.38 GiB (measured)
#   large   94 vCPU / 733Gi  r7i.24xlarge    768 GiB   735.38 GiB (MEASURED)
#   xlarge 126 vCPU / 973Gi  r8i.32xlarge   1024 GiB   975.37 GiB (MEASURED)
#
# All four figures are now MEASURED on real EKS 1.35 AL2023 nodes, not modelled.
# r7i.24xlarge and r8i.32xlarge were booted on pl-lab-cluster (eu-central-1,
# 2026-09-21) and read straight off .status.allocatable.memory; the caps above
# are that value minus ~3 GiB for DaemonSet overhead + safety margin, matching
# the 486.94 -> 484 convention. A job that requests more than true allocatable
# passes Kueue admission and then sits Pending forever, so these must never be
# raised without re-measuring.
#
# Two traps the measurement exposed, both of which a model got wrong:
#   * EKS kube-reserved memory is 255 MiB + 11 MiB * maxPods + 100 MiB eviction
#     -- NOT the tiered percentage formula in _eks_alloc_ram_gib in
#     cloudformation-eks-1-35.yaml, which is the GKE formula and over-reserves
#     by ~3x. That one is still used for the GPU ceilings and is ~8 GiB
#     OPTIMISTIC at 512 GiB; it should be replaced (tracked separately).
#   * maxPods is NOT capped at 737 for every large shape. r7i.24xlarge reserves
#     for 737 pods (8462 MiB) but r8i.32xlarge has 24 ENIs x 64 IPs = 1514 and
#     reserves for all of them (17009 MiB) -- nearly double. Assuming the 737
#     cap put an earlier draft of this table at 976Gi, ABOVE the node's real
#     975.37 GiB allocatable.
# Firmware/kernel loss before kubelet is ~3.15% of nominal on both shapes.
#
# CPU headroom follows the existing convention (2 cores reserved): 64->62,
# 96->94, 128->126.
#
# r7i has no 32xlarge (the family skips 24xl -> 48xl), hence r8i.32xlarge for
# the 1 TiB tier.
#
# REGIONAL COVERAGE (live ec2 describe-instance-type-offerings, 2026-09-21):
# r7i.24xlarge is absent in 17 regions and r8i.32xlarge in 18. Sixteen of those
# are already out of scope for this stack -- r7i.16xlarge, an existing tier, is
# absent there too -- so the only region this actually narrows is
# ap-northeast-3, which has r7i.16xlarge and r7i.24xlarge but NOT r8i.32xlarge.
# Deploying xlarge there will fail to create the 1 TiB node group. The
# CloudFormation template gates on this (Condition RegionHasR8i32xl); this
# module does NOT, so an xlarge apply in ap-northeast-3 errors at the node
# group. Set deployment_size = "large" there.
#
# GCP parity holds at small/medium/large (n2d-highmem-64 / n2d-highmem-96) but
# NOT at xlarge: GCP's largest N2 highmem shape is n2-highmem-128 at 864 GiB
# nominal (~824 GiB allocatable), so an xlarge GCP install caps a single job
# lower than an xlarge AWS install. See terraform-platforma/presets.tf.
# =============================================================================

locals {
  # ---------------------------------------------------------------------------
  # SINGLE SOURCE OF TRUTH: measured allocatable per batch instance type.
  #
  # Every number here was read off a real EKS 1.35 / AL2023 node with
  #   kubectl get node <n> -o jsonpath='{.status.allocatable.{cpu,memory}}'
  # NOT computed. Do not add a row without booting the instance: the reserve
  # depends on maxPods, which is NOT uniformly capped -- r7i.24xlarge reserves
  # for 737 pods (8462 MiB) while r8i.32xlarge has 24 ENIs x 64 IPs = 1514 and
  # reserves for all of them (17009 MiB, nearly double). Modelling that wrong
  # is what put an early draft of the xlarge ceiling at 976Gi, ABOVE the
  # r8i.32xlarge's real 975.37 GiB allocatable -- a job that size would have
  # been admitted by Kueue and then sat Pending forever.
  #
  # The per-job ceilings below are DERIVED from this table, so changing an
  # instance type moves the ceiling with it and the two cannot drift apart.
  # ---------------------------------------------------------------------------
  batch_node_allocatable = {
    "m7i.4xlarge"  = { cpu = 16, memory_gi = 58 }   # 64 GiB nominal
    "m7i.8xlarge"  = { cpu = 32, memory_gi = 119 }  # 128 GiB nominal
    "m7i.16xlarge" = { cpu = 64, memory_gi = 240 }  # 256 GiB nominal
    "r7i.8xlarge"  = { cpu = 32, memory_gi = 240 }  # 256 GiB nominal
    "r7i.16xlarge" = { cpu = 64, memory_gi = 486 }  # 512 GiB nominal, measured 486.94
    "r7i.24xlarge" = { cpu = 96, memory_gi = 735 }  # 768 GiB nominal, measured 735.38
    "r8i.32xlarge" = { cpu = 128, memory_gi = 975 } # 1024 GiB nominal, measured 975.37
  }

  # Largest batch instance type offered at each deployment size. This is the
  # ONLY place the size -> biggest-node relationship is stated; both the node
  # groups (nodegroups.tf) and the per-job ceiling read it.
  largest_batch_type = {
    small  = "r7i.16xlarge"
    medium = "r7i.24xlarge"
    large  = "r7i.24xlarge"
    xlarge = "r8i.32xlarge"
  }


  deployment_sizes = {
    small = {
      batch_cpu           = 126
      batch_memory_gi     = 484
      ui_cpu              = 64
      ui_memory_gi        = 256
      max_batch_16c64g    = 4
      max_batch_32c128g   = 2
      max_batch_64c256g   = 1
      max_batch_32c256g   = 2
      max_batch_64c512g   = 1
      max_batch_96c768g   = 0
      max_batch_128c1024g = 0
      max_gpu_3g          = 2
      max_gpu_6g          = 2
      max_gpu_12g         = 1
      max_gpu_24g         = 1
      max_gpu_48g         = 1
      max_gpu_96g         = 1
      max_ui              = 4
    }
    medium = {
      batch_cpu           = 346
      batch_memory_gi     = 1701
      ui_cpu              = 64
      ui_memory_gi        = 256
      max_batch_16c64g    = 8
      max_batch_32c128g   = 4
      max_batch_64c256g   = 2
      max_batch_32c256g   = 4
      max_batch_64c512g   = 2
      max_batch_96c768g   = 1
      max_batch_128c1024g = 0
      max_gpu_3g          = 4
      max_gpu_6g          = 3
      max_gpu_12g         = 2
      max_gpu_24g         = 2
      max_gpu_48g         = 2
      max_gpu_96g         = 1
      max_ui              = 8
    }
    large = {
      batch_cpu           = 692
      batch_memory_gi     = 3402
      ui_cpu              = 64
      ui_memory_gi        = 256
      max_batch_16c64g    = 16
      max_batch_32c128g   = 8
      max_batch_64c256g   = 4
      max_batch_32c256g   = 8
      max_batch_64c512g   = 4
      max_batch_96c768g   = 2
      max_batch_128c1024g = 0
      max_gpu_3g          = 8
      max_gpu_6g          = 6
      max_gpu_12g         = 4
      max_gpu_24g         = 4
      max_gpu_48g         = 4
      max_gpu_96g         = 2
      max_ui              = 16
    }
    xlarge = {
      batch_cpu           = 1636
      batch_memory_gi     = 8750
      ui_cpu              = 64
      ui_memory_gi        = 256
      max_batch_16c64g    = 32
      max_batch_32c128g   = 16
      max_batch_64c256g   = 8
      max_batch_32c256g   = 16
      max_batch_64c512g   = 8
      max_batch_96c768g   = 4
      max_batch_128c1024g = 2
      max_gpu_3g          = 16
      max_gpu_6g          = 12
      max_gpu_12g         = 8
      max_gpu_24g         = 8
      max_gpu_48g         = 8
      max_gpu_96g         = 4
      max_ui              = 16
    }
  }

  preset = local.deployment_sizes[var.deployment_size]

  # This module does NOT derive a per-job ceiling -- that lives in the platforma
  # module, which carries its own copy of the two tables above (the repo keeps
  # the modules independently appliable, so the tables are duplicated by design
  # and MUST stay in sync). Here the tables justify the node-group instance
  # types and are enforced by the check block below.
}

# Every batch node group's instance type must appear in batch_node_allocatable,
# so renaming or adding a tier cannot silently leave the platforma module
# deriving a ceiling for a node this module no longer creates.
check "batch_types_have_measured_allocatable" {
  assert {
    condition = alltrue([
      for k, v in local.batch_node_groups : contains(keys(local.batch_node_allocatable), v.instance_type)
    ])
    error_message = "every batch node group instance_type must have a MEASURED entry in local.batch_node_allocatable (boot the node and read .status.allocatable)"
  }
}
