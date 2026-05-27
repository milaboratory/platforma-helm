# =============================================================================
# Batch compute: custom ComputeClass
# =============================================================================
# Replaces cluster-wide Node Auto-Provisioning for the batch tier.
#
# Why a ComputeClass instead of bare NAP:
#   Batch jobs request a high memory:CPU ratio (e.g. 62 vCPU / 484 GiB ≈
#   7.8 GiB/vCPU). Cluster-wide NAP without a pinned family shapes nodes
#   within the default E2 family (ratio-capped) and never reaches for
#   predefined highmem machine types on its own — so every batch
#   ProvisioningRequest failed with
#   `no.scale.up.nap.pod.zonal.resources.exceeded` ("no machine type could
#   fit the request"). Naming the highmem machine types explicitly here is
#   the documented fix. Validated on pl-e2e-cluster: a 62/484 pod selecting
#   this class provisions an n2d-highmem-64 node within ~1 min.
#
# Behavior:
#   - priorities[] is an ordered fallback/availability list. The autoscaler
#     skips entries a pod doesn't fit and tries the next; the largest n2d
#     entry falls back to n2-highmem-64 on n2d stockout. It is NOT a per-pod
#     sizing menu — once a large pool exists, smaller pods bin-pack onto it.
#   - nodePoolAutoCreation creates pools on demand (GKE >= 1.33.3 supports
#     this standalone, i.e. without cluster-wide NAP — gke.tf leaves NAP off).
#     Pools scale to zero when idle.
#   - activeMigration.optimizeRulePriority migrates workloads back to the
#     higher-priority family (n2d) once its capacity returns.
#   - Each priority pins a 200 GiB pd-balanced boot disk (batch images:
#     MiXCR + Java/Python toolchains + refs, plus workspace staging).
#   - nodePoolConfig taints (dedicated=batch) + role=batch label isolate and
#     identify batch nodes. GKE also auto-adds
#     cloud.google.com/compute-class=platforma-batch (taint + auto-injected
#     pod toleration).
#
# Pods opt in via nodeSelector cloud.google.com/compute-class=platforma-batch
# (wired through the chart in app.tf: kueue.pools.batch.nodeSelector).
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
      priorities = [
        for mt in local.batch_machine_priorities : {
          machineType = mt
          spot        = false
          storage = {
            bootDiskSize = 200
            bootDiskType = "pd-balanced"
          }
        }
      ]
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
    data.google_container_cluster.primary,
  ]
}
