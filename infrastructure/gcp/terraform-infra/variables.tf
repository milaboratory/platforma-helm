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

variable "vpc_name" {
  type        = string
  description = "VPC network name."
  default     = "platforma-vpc"
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
  description = "Machine type for system node pool (Platforma server, Kueue, AppWrapper, controllers)."
  default     = "n2d-standard-8"
}

variable "system_pool_node_count" {
  type        = number
  description = "Number of nodes in the system pool (fixed, not autoscaled). 1 is sufficient for Platforma: the server pod is single-instance, so a spare node doesn't reduce downtime on node failure (K8s reschedules in minutes either way). Matches the AWS CloudFormation default. Increase to 2+ only if you have an explicit HA strategy."
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
  type = map(number)
  description = <<-EOT
    DEPRECATED — no-op since the Node Auto-Provisioning migration. Batch
    capacity is now governed by a cluster-wide envelope (batch_capacity in
    presets.tf, NAP resource_limits in gke.tf), not per-pool max-node
    counts. Override the envelope via var.kueue_batch_queue_cpu /
    var.kueue_batch_queue_memory instead. Variable kept for tfvars
    backwards-compatibility; will be removed in a future release.
  EOT
  default = {}
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

# -----------------------------------------------------------------------------
# Quota auto-request
# -----------------------------------------------------------------------------

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
