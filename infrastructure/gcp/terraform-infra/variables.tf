# =============================================================================
# Infra module variables
# =============================================================================
# This module provisions: networking, GKE cluster + node pools, GCS bucket,
# Filestore, IAM service accounts, DNS records + Certificate Manager certmap,
# Cloud Quotas pre-requests. It does NOT run any kubectl/helm/kubernetes
# resources — those live in the platforma module, which depends on this one.
# =============================================================================

variable "project_id" {
  type        = string
  description = "GCP project ID to deploy into."
}

variable "region" {
  type        = string
  description = "GCP region for regional resources."
  default     = "europe-west1"
}

variable "zone_suffix" {
  type        = string
  description = "Zone suffix (a/b/c/d) within the region, used for zonal resources (Filestore Zonal, persistent disks). Cannot be changed after initial deployment without data migration."
  default     = "b"

  validation {
    condition     = can(regex("^[a-d]$", var.zone_suffix))
    error_message = "zone_suffix must be one of: a, b, c, d."
  }
}

variable "cluster_name" {
  type        = string
  description = "GKE cluster name. Lowercase alphanumeric + hyphens, 1-25 chars."
  default     = "platforma-cluster"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,24}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, 1-25 chars, starting with a letter or digit."
  }
}

variable "deployment_size" {
  type        = string
  description = "Cluster sizing profile. Controls node pool maxes, Filestore default capacity, and quota auto-request amounts. Mirrors AWS CloudFormation parallelism."
  default     = "small"

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.deployment_size)
    error_message = "deployment_size must be one of: small, medium, large, xlarge."
  }
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------

variable "resource_name_prefix" {
  type        = string
  description = "Prefix for project-scoped resources whose default names would otherwise collide when multiple Platforma deployments share one GCP project (VPC, server/jobs service accounts). Default 'platforma' preserves legacy naming."
  default     = "platforma"
}

variable "vpc_name" {
  type        = string
  description = "VPC network name. If null, derived as '<resource_name_prefix>-vpc'."
  default     = null
}

variable "subnet_nodes_cidr" {
  type        = string
  description = "Primary CIDR for the GKE node subnet."
  default     = "10.0.0.0/20"
}

variable "subnet_pods_cidr" {
  type        = string
  description = "Secondary CIDR for pod IPs (VPC-native GKE)."
  default     = "10.1.0.0/16"
}

variable "subnet_services_cidr" {
  type        = string
  description = "Secondary CIDR for Kubernetes service IPs."
  default     = "10.2.0.0/20"
}

variable "master_ipv4_cidr_block" {
  type        = string
  description = "Reserved /28 CIDR for the GKE master's private endpoint. Must not overlap with subnet_nodes_cidr / subnet_pods_cidr / subnet_services_cidr or any peered network. Required by GCP even when enable_private_endpoint = false (public control plane)."
  default     = "10.10.0.0/28"

  validation {
    condition     = can(regex("/28$", var.master_ipv4_cidr_block))
    error_message = "master_ipv4_cidr_block must be a /28 CIDR (GCP requires exactly /28 for the master endpoint)."
  }
}

variable "enable_private_nodes" {
  type        = bool
  description = <<-EOT
    Whether GKE worker nodes have only internal IPs (true) or get external
    IPs (false). Default true — production-recommended; saves IN_USE_ADDRESSES
    quota and improves security posture. Egress for private nodes routes
    through Cloud NAT (created automatically when this is true).
  EOT
  default     = true
}

# -----------------------------------------------------------------------------
# Node pools
# -----------------------------------------------------------------------------

variable "system_pool_machine_type" {
  type        = string
  description = "Machine type for the system node pool. Hosts cluster-support services only (Kueue, AppWrapper, controllers, CoreDNS, CSI, metrics-server) — the Platforma backend runs on its own dedicated pool (platforma_pool_machine_type), so this can stay small. n2d-standard-4 (4 vCPU / 16 GiB) is ample for the services."
  default     = "n2d-standard-4"
}

variable "system_pool_node_count" {
  type        = number
  description = "Number of nodes in the system pool (fixed, not autoscaled). 1 is sufficient: the cluster services fit comfortably on one node. Increase to 2+ only if you have an explicit HA strategy for the services."
  default     = 1
}

variable "platforma_pool_machine_type" {
  type        = string
  description = "Machine type for the dedicated Platforma backend node pool. Split out from the system pool (MILAB-6566) so the server pod's memory can grow into a whole node without contending with cluster services. n2d-standard-16 (~58 GiB allocatable) realizes the chart's 32 GiB memory limit with headroom; n2d-standard-8 (~26 GiB allocatable) would cap the pod below its limit."
  default     = "n2d-standard-16"
}

variable "platforma_pool_node_count" {
  type        = number
  description = "Number of nodes in the dedicated Platforma backend pool (fixed, not autoscaled). The backend is a single-instance pod, so 1 is correct. Increase only with an explicit HA strategy."
  default     = 1
}

variable "ui_pool_machine_type" {
  type        = string
  description = "Machine type for UI node pool."
  default     = "n2d-standard-4"
}

variable "ui_pool_max_nodes" {
  type        = number
  description = "Override max nodes in the UI pool (scales from 0). null = use deployment_size preset default."
  default     = null
}

variable "batch_pool_max_nodes_overrides" {
  type        = map(number)
  description = <<-EOT
    DEPRECATED — no-op since the Node Auto-Provisioning migration. Batch
    capacity is now governed by a cluster-wide envelope (batch_capacity in
    presets.tf, NAP resource_limits in gke.tf), not per-pool max-node
    counts. Override the envelope via var.kueue_batch_queue_cpu /
    var.kueue_batch_queue_memory instead. Variable kept for tfvars
    backwards-compatibility; will be removed in a future release.
  EOT
  default     = {}
}

variable "batch_pool_disk_size_gb" {
  type        = number
  description = "Boot disk size for batch nodes. NOTE: batch nodes are now provisioned by the ComputeClass (terraform-platforma/computeclass.tf), which sets pd-balanced boot disks; this variable is retained for the SSD-quota sizing math and any future static-pool fallback. Sized for the largest batch shape — big container images (MiXCR, Java/Python toolchains, refs) plus workspace staging. Counts against Persistent Disk SSD quota."
  default     = 200
}

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

variable "filestore_tier" {
  type        = string
  description = "Filestore tier. ZONAL (SSD, 1 TiB min) is the recommended production default."
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "BASIC_SSD", "BASIC_HDD", "REGIONAL", "ENTERPRISE"], var.filestore_tier)
    error_message = "filestore_tier must be one of: ZONAL, BASIC_SSD, BASIC_HDD, REGIONAL, ENTERPRISE."
  }
}

variable "workspace_capacity_gb" {
  type        = number
  description = "Override Filestore capacity in GiB. null = deployment_size preset default."
  default     = null

  validation {
    condition     = var.workspace_capacity_gb == null ? true : var.workspace_capacity_gb >= 1024
    error_message = "workspace_capacity_gb must be null (use preset) or >= 1024 (1 TiB)."
  }
}

variable "workspace_share_name" {
  type        = string
  description = "Filestore file share name (mount path on the instance)."
  default     = "platforma"
}

variable "gcs_bucket_name" {
  type        = string
  description = "Primary GCS bucket name. Empty = auto-generate 'platforma-<cluster>-<random>'."
  default     = ""
}

variable "gcs_force_destroy" {
  type        = bool
  description = "Allow terraform destroy to delete the primary GCS bucket even when it still contains objects. DEFAULT FALSE."
  default     = false
}

# -----------------------------------------------------------------------------
# Application namespace + workload identity coordinates
# -----------------------------------------------------------------------------
# These are also passed to the platforma module so K8s SA names line up with
# Workload Identity bindings declared here.
# -----------------------------------------------------------------------------

variable "platforma_namespace" {
  type        = string
  description = "Kubernetes namespace for Platforma. Used in Workload Identity trust bindings."
  default     = "platforma"
}

variable "helm_release_name" {
  type        = string
  description = "Helm release name for Platforma. K8s service accounts will be named <release> (server) and <release>-jobs."
  default     = "platforma"
}

# -----------------------------------------------------------------------------
# Data libraries — IAM bindings only (GCS bucket roles). The actual K8s
# secret materialisation happens in the platforma module.
# -----------------------------------------------------------------------------

variable "data_libraries" {
  type = list(object({
    name   = string
    type   = string
    bucket = string
    prefix = optional(string, "")
    # GCS-only fields
    project_id = optional(string, "")
    # S3-only fields (also works for cross-project GCS via HMAC + custom endpoint)
    region            = optional(string, "")
    endpoint          = optional(string, "")
    external_endpoint = optional(string, "")
    access_key        = optional(string, "")
    secret_key        = optional(string, "")
  }))
  default     = []
  description = "External read-only data libraries. The infra module uses the GCS entries to grant the platforma runtime SAs roles/storage.objectViewer on same-project buckets; the platforma module materialises K8s Secrets for S3 entries. Pass the same value to both modules."
}

# -----------------------------------------------------------------------------
# Ingress / TLS — Certificate Manager + Cloud DNS only.
# Gateway/HTTPRoute live in the platforma module, but the certmap and DNS
# records they depend on are GCP-side and live here.
# -----------------------------------------------------------------------------

variable "ingress_enabled" {
  type        = bool
  description = "Enable HTTPS ingress (Cloud DNS A record + Certificate Manager managed cert + Static IP). Gateway/HTTPRoute on the K8s side are gated on the same flag in the platforma module."
  default     = false
}

variable "domain_name" {
  type        = string
  description = "Fully-qualified domain for Platforma (e.g. platforma.example.com). Required when ingress_enabled = true."
  default     = ""
}

variable "dns_zone_name" {
  type        = string
  description = "Cloud DNS managed zone name that controls domain_name. Required when ingress_enabled = true."
  default     = ""
}

variable "dns_zone_project" {
  type        = string
  description = "GCP project hosting the Cloud DNS managed zone, if different from project_id. Empty = same as project_id."
  default     = ""
}

# -----------------------------------------------------------------------------
# Optional IAM extensions
# -----------------------------------------------------------------------------

variable "enable_google_batch" {
  type        = bool
  description = <<-EOT
    Grant the platforma-server GCP service account the IAM roles required to
    submit and supervise Google Batch jobs from the Platforma server.

    When true, the following roles are bound to the platforma-server SA:
      roles/batch.jobsEditor       — create/list/cancel Batch jobs in the project
      roles/batch.agentReporter    — Batch agent on the VMs reports state back
      roles/batch.serviceAgent     — Batch service agent operations
      roles/iam.serviceAccountUser — self-impersonation so Batch VMs can
                                     run-as the platforma-server SA

    Default false — the standard GKE-based deployment runs workflow jobs as
    in-cluster pods via Kueue/AppWrapper and does not need the Batch API.
    Set to true only for developer/preview installs that exercise the Google
    Batch runner backend.
  EOT
  default     = false
}

variable "gpu_l4_pools" {
  type        = map(list(string))
  description = <<-EOT
    Map of L4 GPU machine shape (g2-standard-*) -> the zones its node pool may
    create nodes in. One node pool is created per key (adaptive ladder — a
    region provisions only the shapes it actually offers).

    Normally populated by install.sh at deploy time — it calls gcptest.sh
    discover for nvidia-l4 in var.region, which returns, per shape, the zones
    that offer it (shapes offered in no zone are omitted). Operators do not set
    this by hand.

    Three cases (see effective_gpu_l4_pools in presets.tf):
      - null              running terraform directly without install.sh: falls
                          back to the full default ladder
                          (local.default_gpu_l4_ladder) in [local.zone].
      - {}                install.sh found L4 is not offered in var.region: L4
                          pools are disabled (gpu_l4_enabled = false).
      - {shape=[zone..]}  discovered per-shape zones for L4.
  EOT
  default     = null
}

variable "gpu_rtx_pro_6000_pools" {
  type        = map(list(string))
  description = <<-EOT
    Map of RTX PRO 6000 machine shape (g4-standard-*) -> zones for that shape's
    node pool. Same install.sh-driven discovery and null/{}/{shape=[zones]}
    semantics as gpu_l4_pools.
  EOT
  default     = null
}

variable "enable_gpu" {
  type        = bool
  description = <<-EOT
    Provision GPU support on the cluster.

    When true:
      - terraform-infra/gke.tf creates static node pools for both GPU SKUs:
          * L4 (24 GiB VRAM): 5 pools g2-standard-{4,8,12,16,32}, each 1× L4
          * RTX PRO 6000 (96 GiB VRAM): 4 pools g4-standard-{6,12,24,48},
            each 1× nvidia-rtx-pro-6000
        Each pool carries node labels role=gpu + platforma.bio/gpu-memory-gib
        (24 or 96), taint nvidia.com/gpu=present:NoSchedule, and autoscales
        0..N (sized via gpu_l4_max_nodes_per_shape /
        gpu_rtx_pro_6000_max_nodes_per_shape in presets.tf).
      - terraform-platforma enables kueue.pools.gpu in the Helm chart
        (nvidia-device-plugin DaemonSet, GPU ResourceFlavor + ClusterQueue,
        --runner-gpu-available flag). The GPU ClusterQueue admission cap is
        sized from gpu_capacity in presets.tf (override via
        var.kueue_gpu_queue_*).

    Pod routing is by node label: the job template emits nodeAffinity on
    platforma.bio/gpu-memory-gib and the GKE Cluster Autoscaler pre-creation-
    matches that against each pool's template node labels (the same
    mechanism AWS Cluster Autoscaler uses with node-template tags). Pods
    requesting ≤ 24 GiB land on L4; > 24 GiB land on RTX PRO 6000; the L4
    preferred-Lt clause + CA's least-waste expander keep small jobs on L4.

    Each GPU pool spans the zones in var.region where its machine shape is
    offered — discovered per shape by install.sh via gcptest.sh discover and
    embedded in var.gpu_l4_pools / var.gpu_rtx_pro_6000_pools automatically.
    Shapes offered in no zone are dropped; a SKU offered nowhere is skipped;
    if neither SKU is available install.sh continues CPU-only. System and UI
    pools stay in the cluster's primary zone (local.zone).

    Default true — GPU support is opt-out. Set false to skip all
    GPU node pools and Kueue GPU wiring.

    NVIDIA_L4_GPUS and NVIDIA_RTX_PRO_6000_GPUS regional quotas are required
    for the pools to actually provision nodes. quotas.tf auto-requests these
    (sized from the deployment_size preset) when enable_quota_auto_request is
    true — the empty scale-to-zero pools consume no GPU quota at apply time, so
    a still-pending request only leaves GPU jobs Pending, never fails apply.
  EOT
  default     = true
}

# -----------------------------------------------------------------------------
# Quota auto-request
# -----------------------------------------------------------------------------

# Whether to submit the per-SKU GPU quota-increase request, DECOUPLED from
# whether that SKU's node pools are actually created. install.sh sets these true
# whenever a SKU is offered in the region (so the increase is requested) even
# when it also empties gpu_*_pools because the current quota is still below the
# deployment's need — that lets Platforma come up GPU-less for that SKU now and
# pick it up on a re-install once the quota lands. null (bare terraform, no
# install.sh) falls back to var.enable_gpu (see effective_request_gpu_*_quota).
variable "request_gpu_l4_quota" {
  type        = bool
  description = "Submit the NVIDIA L4 GPU quota-increase request, independent of pool creation. null = follow var.enable_gpu."
  default     = null
}

variable "request_gpu_rtx_pro_6000_quota" {
  type        = bool
  description = "Submit the NVIDIA RTX PRO 6000 GPU quota-increase request, independent of pool creation. null = follow var.enable_gpu."
  default     = null
}

variable "enable_quota_auto_request" {
  type        = bool
  description = "Submit quota-increase requests via google_cloud_quotas_quota_preference based on the deployment_size preset."
  default     = true
}

variable "contact_email" {
  type        = string
  description = "Email for GCP to send quota approval/rejection notifications. Required when enable_quota_auto_request = true."
  default     = ""
}

variable "skip_quota_requests" {
  type        = list(string)
  description = "Quota request keys to skip even when enable_quota_auto_request = true."
  default     = []
}

# -----------------------------------------------------------------------------
# Kueue / Job sizing
# -----------------------------------------------------------------------------
# Read here only so quotas can size N2D CPU quota against the same cap the
# platforma module uses for Kueue ClusterQueue sizing. Both modules consume
# the same presets.tf to keep the math consistent.
# -----------------------------------------------------------------------------

variable "kueue_max_job_cpu" {
  type        = number
  description = "Override max vCPU per single job. null = preset default (62)."
  default     = null
}

variable "kueue_max_job_memory" {
  type        = string
  description = "Override max memory per single job. null = preset default (500Gi)."
  default     = null
}

variable "kueue_batch_queue_cpu" {
  type        = number
  description = "Override batch ClusterQueue CPU quota. null = computed from preset."
  default     = null
}

variable "kueue_batch_queue_memory" {
  type        = string
  description = "Override batch ClusterQueue memory quota. null = computed from preset."
  default     = null
}
