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
#   fit the request"). Naming the machine types explicitly here is the
#   documented fix. Validated on pl-e2e-cluster against an earlier,
#   shorter priority list: a 62/484 pod selecting this class provisioned an
#   n2d-highmem-64 node within ~1 min. That shape now sits 11th rather than
#   4th, so treat the timing as indicative, not re-measured.
#
#   The priority list, whenUnsatisfiable and activeMigration settings below
#   are ported from the GSK production deployment (app-mixcr-gcp,
#   apps/computeclass/platforma-batch.yaml), where they were shaped by real
#   stockouts and real job shapes — see the per-field notes.
#
# Behavior:
#   - priorities[] (presets.tf batch_machine_priorities) is an ordered
#     fallback/availability list, sorted smallest-first across size tiers,
#     interleaving both memory:CPU ratios (at each vCPU count the standard
#     shape, 4 GiB/vCPU, comes ahead of the highmem shape of the same vCPU
#     count, 8 GiB/vCPU) with n2d then n2 in every tier. The
#     autoscaler skips entries a pod doesn't fit and tries the next, so a small
#     job lands on a small node
#     and a large job falls through to the large/xlarge tiers. It is NOT a
#     per-pod sizing menu — once a large pool exists, smaller pods bin-pack
#     onto it.
#   - nodePoolAutoCreation creates pools on demand (GKE >= 1.33.3 supports
#     this standalone, i.e. without cluster-wide NAP — gke.tf leaves NAP off).
#     Pools scale to zero when idle.
#   - whenUnsatisfiable: ScaleUpAnyway overrides the GKE 1.33+ default of
#     DoNotScaleUp. With DoNotScaleUp, a pod that no listed priority can
#     satisfy (a region-wide stockout) just pends — and its ProvisioningRequest
#     booking expires meanwhile, after which the autoscaler refuses to scale up
#     for that pod ever again (IgnoredInScaleUp / BookingExpired) and the
#     AppWrapper grace period deletes it. ScaleUpAnyway lets the autoscaler fall
#     back to the cluster's default machine configuration instead of giving up,
#     turning a permanent stall into a possibly-suboptimal node. Trade-off: such
#     nodes ignore the curated priorities above, so watch for unexpected machine
#     types after a stockout. Observed at GSK on 2026-09-03 (GCE reported "out
#     of resources" for a whole zone and nothing was created at all).
#     NOTE: the fallback is REAL, not inert, and it is E2. The GKE docs are
#     explicit: "In Standard clusters that use node pool auto-creation, GKE
#     might create a new node pool that uses the default E2 machine series to
#     place the Pod" — and nodePoolAutoCreation is enabled below, so that is
#     exactly this cluster (cluster-wide NAP being off does not change it).
#     E2 tops out at 128 GiB, so it can never rescue the 62/484 job this
#     setting was added for; what it CAN do is quietly place a mid-sized batch
#     job on an E2 node at a fraction of the expected throughput. That is the
#     deliberate trade: a slow node beats a permanently stalled job. The real
#     fix for a recurring stockout is adding machine types to
#     batch_machine_priorities, not relying on this. See
#     https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-custom-compute-classes
#   - activeMigration.optimizeRulePriority is OFF. It evicts and recreates
#     RUNNING pods to move them onto higher-priority nodes. Because the list is
#     ordered smallest-first with no spot/on-demand tiering, "higher priority"
#     here just means SMALLER — there is no cost arbitrage to win, only
#     disruption. Batch jobs run for hours and are not restartable, and GKE
#     honours only PodDisruptionBudgets + graceful termination during such a
#     migration (not the safe-to-evict=false annotation Platforma sets on these
#     pods).
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
      whenUnsatisfiable = "ScaleUpAnyway"
      activeMigration = {
        optimizeRulePriority = false
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
