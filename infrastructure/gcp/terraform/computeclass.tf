# =============================================================================
# Batch compute: custom ComputeClass
# =============================================================================
# Replaces the static per-shape batch node pools (formerly
# google_container_node_pool.batch in gke.tf) with a single GKE ComputeClass
# that provisions batch nodes on demand across MULTIPLE instance families.
#
# Why a ComputeClass:
#   1. Cross-family capacity fallback. A static pool is pinned to one machine
#      type in one family; when that family is out of capacity in the zone
#      (ZONE_RESOURCE_POOL_EXHAUSTED) the pool cannot scale and batch jobs hang
#      pending indefinitely. The ComputeClass priorities[] list is an ordered
#      fallback: the autoscaler skips a family it can't provision and tries the
#      next (n2d → n2 → standard), so batch survives an AMD/N2D stockout by
#      shifting to Intel/N2.
#   2. High memory:CPU ratio. Batch jobs request ~7.8 GiB/vCPU (e.g. 62 vCPU /
#      484 GiB). Bare cluster-wide NAP shapes within the default E2 family and
#      never reaches predefined highmem types on its own, so it fails with
#      no.scale.up.nap.pod.zonal.resources.exceeded. Naming the highmem machine
#      types explicitly here is the documented fix.
#
#   3. Cross-ZONE capacity fallback. Machine-family fallback still fails if the
#      whole primary zone is stocked out. priorities[] is expanded as a
#      zone-major x family-minor matrix (see local.batch_priority_zone_tiers):
#      the full family ladder is tried in the Filestore zone first (tier 1),
#      then in var.batch_fallback_zone_suffixes (tier 2). location.zones on each
#      priority drives this; nodePoolAutoCreation places pools in the chosen
#      zone. Trade-off: tier-2 batch nodes mount the ZONAL Filestore cross-zone
#      (egress cost + latency), so tier 1 stays preferred and activeMigration
#      pulls batch back once the primary zone recovers.
#
# Behavior:
#   - priorities[] (local.batch_machine_priorities x
#     local.batch_priority_zone_tiers) is an ordered fallback/availability list,
#     NOT a per-pod sizing menu — once a large pool exists, smaller pods
#     bin-pack onto it.
#   - nodePoolAutoCreation creates pools on demand. This is a STANDALONE GKE
#     capability (GKE >= 1.33.3) — it does NOT require cluster-wide Node
#     Auto-Provisioning, and gke.tf leaves NAP off (cluster_autoscaling has
#     only autoscaling_profile). Pools scale to zero when idle.
#   - activeMigration.optimizeRulePriority migrates workloads back to the
#     higher-priority family (n2d) once its capacity returns.
#   - Each priority pins a 200 GiB pd-balanced boot disk (batch images: MiXCR +
#     Java/Python toolchains + refs, plus workspace staging).
#   - nodePoolConfig taints (dedicated=batch) + role=batch label isolate and
#     identify batch nodes. GKE also auto-adds
#     cloud.google.com/compute-class=platforma-batch (taint + auto-injected
#     pod toleration).
#
# Batch pods opt in via nodeSelector cloud.google.com/compute-class=platforma-batch
# (wired through the chart in app.tf: kueue.pools.batch.nodeSelector). That
# selector both ATTRACTS pods to ComputeClass nodes and TRIGGERS the class's
# node-pool auto-creation.
#
# ComputeClass is a GKE-managed CRD (apiVersion cloud.google.com/v1), GA since
# GKE 1.32.1. Applied as a raw manifest — no native google_container_*
# Terraform resource exists.
resource "kubectl_manifest" "batch_compute_class" {
  yaml_body = yamlencode({
    apiVersion = "cloud.google.com/v1"
    kind       = "ComputeClass"
    metadata = {
      name = "platforma-batch"
    }
    spec = {
      # priorities[] is a flat ordered fallback list. We expand it as a
      # zone-major x family-minor matrix (local.batch_priority_zone_tiers x
      # local.batch_machine_priorities): the FULL machine-family ladder is tried
      # in the preferred (Filestore) zone first, and only spills to fallback
      # zones once every family is capacity-exhausted there. Each priority pins
      # both the machine type AND its tier's location.zones — GKE supports
      # combining machineType + location in one priority entry.
      priorities = flatten([
        for zones in local.batch_priority_zone_tiers : [
          for mt in local.batch_machine_priorities : {
            machineType = mt
            spot        = false
            storage = {
              bootDiskSize = 200
              bootDiskType = "pd-balanced"
            }
            location = {
              zones = zones
            }
          }
        ]
      ])
      # DoNotScaleUp: if no priority can be satisfied (all families exhausted in
      # all listed zones), leave pods Pending rather than fall back to a node
      # with the cluster's DEFAULT machine config. ScaleUpAnyway would create an
      # E2/standard-shaped node, which cannot express the batch memory:CPU ratio
      # (~7.8 GiB/vCPU) and would hang the job on
      # no.scale.up.nap.pod.zonal.resources.exceeded — the exact failure this
      # ComputeClass exists to prevent.
      whenUnsatisfiable = "DoNotScaleUp"
      nodePoolAutoCreation = {
        enabled = true
      }
      activeMigration = {
        optimizeRulePriority = true
      }
      nodePoolConfig = {
        taints = [
          {
            key    = "dedicated"
            value  = "batch"
            effect = "NoSchedule"
          },
        ]
        nodeLabels = {
          role = "batch"
        }
      }
    }
  })

  # The cluster (and its GKE-managed ComputeClass CRD) must exist first.
  depends_on = [
    google_container_cluster.primary,
  ]
}
