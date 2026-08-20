{{- /*
platforma.validateNodeSelectors — fails render when a Kueue pool is
half-configured for workload separation: it declares tolerations (implying
dedicated, tainted nodes exist for it) but leaves nodeSelector empty.

Why this is a trap:
  A toleration only PERMITS a pod onto tainted nodes — it never ATTRACTS it
  there. Without a nodeSelector the pool's ResourceFlavor matches no nodes (or
  the wrong ones), so jobs land on shared nodes instead of their dedicated
  pool. On GKE, the batch ComputeClass node auto-creation is triggered by the
  cloud.google.com/compute-class nodeSelector — with no selector, large jobs
  never get a node created and sit Pending forever with no error.

Scope / limits:
  - Only runs in dedicated mode when this release creates the cluster-scoped
    Kueue resources (matches the condition in kueue-resourceflavors.yaml).
  - A both-empty pool (no selector, no tolerations) is left alone — that is the
    legitimate flat / single-node cluster layout (e.g. CI, k3s).
  - Cannot verify the selector KEY matches a node's real label; the chart has
    no view of node labels. This guards only against the half-configured pair.
*/ -}}
{{- define "platforma.checkPoolNodeSelector" -}}
{{- $ctx := .ctx -}}
{{- $pool := .pool -}}
{{- $cfg := index $ctx.Values.kueue.pools $pool -}}
{{- $sel := default (dict) $cfg.nodeSelector -}}
{{- $tol := default (list) $cfg.tolerations -}}
{{- if and (gt (len $tol) 0) (eq (len $sel) 0) -}}
{{- /* The GKE ComputeClass selector applies to batch only (it triggers the
       batch node auto-creation); the ui pool uses a plain node-pool label. */ -}}
{{- $gke := "" -}}
{{- if eq $pool "batch" -}}
{{- $gke = "\n    GKE ComputeClass: { cloud.google.com/compute-class: platforma-batch }" -}}
{{- end -}}
{{- fail (printf "ERROR: kueue.pools.%s declares tolerations but nodeSelector is empty.\n\n  A toleration only permits a pod onto tainted nodes; it does not pull it there.\n  In dedicated mode the %s ResourceFlavor then matches no dedicated nodes, so %s\n  jobs mis-schedule onto shared nodes — and on GKE the ComputeClass node\n  auto-creation is never triggered, leaving large jobs Pending indefinitely.\n\n  Fix one of:\n  A: set kueue.pools.%s.nodeSelector to the label your %s nodes carry\n    GKE node pool: { pool: %s }\n    AWS:           { node.kubernetes.io/pool: %s }%s\n  B: no dedicated %s nodes on this cluster? Also clear\n    kueue.pools.%s.tolerations (flat cluster — all pods co-scheduled)."
    $pool $pool $pool $pool $pool $pool $pool $gke $pool $pool) -}}
{{- end -}}
{{- end -}}

{{- /* Always enforced (no opt-out): a half-configured pool silently strands
       jobs, which is never an intended state. */ -}}
{{- define "platforma.validateNodeSelectors" -}}
{{- if and (eq .Values.kueue.mode "dedicated") .Values.kueue.dedicated.createClusterResources -}}
  {{- include "platforma.checkPoolNodeSelector" (dict "ctx" . "pool" "ui") -}}
  {{- include "platforma.checkPoolNodeSelector" (dict "ctx" . "pool" "batch") -}}
{{- end -}}
{{- end -}}
