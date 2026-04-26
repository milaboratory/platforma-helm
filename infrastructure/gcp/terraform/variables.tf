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
  description = "Cluster sizing profile. Controls node pool maxes, Kueue batch queue quotas, Filestore default capacity, and quota auto-request amounts. All sizes share the same per-job cap (62 vCPU / 500 GiB). small=4 parallel jobs, medium=8, large=16, xlarge=32. Mirrors AWS CloudFormation parallelism."
  default     = "small"

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.deployment_size)
    error_message = "deployment_size must be one of: small, medium, large, xlarge."
  }
}

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

variable "system_pool_machine_type" {
  type        = string
  description = "Machine type for system node pool (Platforma server, Kueue, controllers)."
  default     = "n2d-standard-4"
}

variable "system_pool_node_count" {
  type        = number
  description = "Number of nodes in the system pool (fixed, not autoscaled)."
  default     = 2
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
    Per-batch-pool max-nodes override map. Keys are batch pool shape IDs:
      "16c-64g", "32c-128g", "64c-256g", "32c-256g", "64c-512g"
    Values are the autoscaler max-node count for that pool. Empty map (default)
    uses the deployment_size preset values (see presets.tf batch_pool_max_nodes
    per preset). Override only the pools you want to change; others fall back
    to preset.

    Examples:
      batch_pool_max_nodes_overrides = { "64c-512g" = 4 }
        # Keep small preset defaults except allow up to 4 huge-memory nodes.

      batch_pool_max_nodes_overrides = {
        "16c-64g"  = 0
        "32c-128g" = 0
        "32c-256g" = 0
      }
        # Disable smaller pools entirely (only run on 64c-256g + 64c-512g).

    Pool shapes mirror AWS CloudFormation's batch node groups:
      16c-64g  → n2d-standard-16 (16 vCPU / 64 GiB,  AWS m7i.4xlarge)
      32c-128g → n2d-standard-32 (32 vCPU / 128 GiB, AWS m7i.8xlarge)
      64c-256g → n2d-standard-64 (64 vCPU / 256 GiB, AWS m7i.16xlarge)
      32c-256g → n2d-highmem-32  (32 vCPU / 256 GiB, AWS r7i.8xlarge)
      64c-512g → n2d-highmem-64  (64 vCPU / 512 GiB, AWS r7i.16xlarge)
    All pools share the same K8s label (role=batch) and taint
    (dedicated=batch:NoSchedule); the GKE autoscaler picks the smallest-
    fitting pool per pending pod.
  EOT
  default     = {}

  validation {
    condition = alltrue([
      for k, _ in var.batch_pool_max_nodes_overrides :
      contains(["16c-64g", "32c-128g", "64c-256g", "32c-256g", "64c-512g"], k)
    ])
    error_message = "batch_pool_max_nodes_overrides keys must be one of: 16c-64g, 32c-128g, 64c-256g, 32c-256g, 64c-512g."
  }
}

variable "batch_pool_disk_size_gb" {
  type        = number
  description = "Boot disk size for batch nodes. Counts against Persistent Disk SSD quota."
  default     = 100
}

variable "kueue_max_job_cpu" {
  type        = number
  description = "Override max vCPU per single job. null = 62 (fixed across all presets, fits n2d-highmem-64 after daemonset overhead). Lower this only if your batch machine type is smaller."
  default     = null
}

variable "kueue_max_job_memory" {
  type        = string
  description = "Override max memory per single job. null = 500Gi (fixed across all presets)."
  default     = null
}

variable "kueue_batch_queue_cpu" {
  type        = number
  description = "Override batch ClusterQueue CPU quota (total across parallel jobs). null = preset.parallel_jobs * 62."
  default     = null
}

variable "kueue_batch_queue_memory" {
  type        = string
  description = "Override batch ClusterQueue memory quota. null = preset.parallel_jobs * 500Gi."
  default     = null
}

variable "filestore_tier" {
  type        = string
  description = "Filestore tier. ZONAL (SSD, 1 TiB min) is the recommended production default — HDD does not handle real bioinformatics load. BASIC_SSD (2.5 TiB min), REGIONAL (multi-zone SSD, 1 TiB min) and ENTERPRISE are SSD alternatives. BASIC_HDD (1 TiB min) is kept for testing only; not suitable for production workloads."
  default     = "ZONAL"

  validation {
    condition     = contains(["ZONAL", "BASIC_SSD", "BASIC_HDD", "REGIONAL", "ENTERPRISE"], var.filestore_tier)
    error_message = "filestore_tier must be one of: ZONAL, BASIC_SSD, BASIC_HDD, REGIONAL, ENTERPRISE."
  }
}

variable "workspace_capacity_gb" {
  type        = number
  description = "Override Filestore capacity in GiB. null = deployment_size preset default. Min 1024 for ZONAL/REGIONAL/ENTERPRISE/BASIC_HDD; min 2560 for BASIC_SSD. Resize up later via gcloud (online, no downtime)."
  default     = null

  validation {
    # Use ternary to short-circuit explicitly — TF 1.5's || does NOT
    # short-circuit inside validation conditions, so 'null >= 1024' would
    # error with "argument must not be null" before we ever check null.
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

variable "platforma_namespace" {
  type        = string
  description = "Kubernetes namespace for Platforma. Used in Workload Identity trust bindings."
  default     = "platforma"
}

variable "helm_release_name" {
  type        = string
  description = "Helm release name for Platforma. K8s service accounts will be named <release>-platforma and <release>-platforma-jobs."
  default     = "platforma"
}

variable "kueue_version" {
  type        = string
  description = "Kueue Helm chart version."
  default     = "0.16.1"
}

variable "appwrapper_version" {
  type        = string
  description = "AppWrapper release tag (used in install.yaml URL)."
  default     = "v1.2.0"
}

variable "license_key" {
  type        = string
  description = "Platforma license key (MI_LICENSE)."
  sensitive   = true
}

variable "platforma_chart_version" {
  type        = string
  description = "Platforma chart version (empty = use chart default)."
  default     = ""
}

variable "ingress_enabled" {
  type        = bool
  description = "Enable HTTPS ingress (Cloud DNS A record + Certificate Manager managed cert + GKE Gateway). When false, connect via kubectl port-forward (development only). Required for the Desktop App in production. When true, you must also set domain_name and dns_zone_name."
  default     = false
}

variable "domain_name" {
  type        = string
  description = "Fully-qualified domain for Platforma (e.g. platforma.example.com). The Desktop App connects here over HTTPS. Required when ingress_enabled = true."
  default     = ""
}

variable "dns_zone_name" {
  type        = string
  description = "Cloud DNS managed zone name that controls domain_name (e.g. 'example-com'). Required when ingress_enabled = true. The zone must already exist; create it via 'gcloud dns managed-zones create' and delegate from your registrar — see infrastructure/gcp/domain-guide.md."
  default     = ""
}

variable "dns_zone_project" {
  type        = string
  description = "GCP project hosting the Cloud DNS managed zone, if different from project_id. Empty = same as project_id."
  default     = ""
}

variable "admin_username" {
  type        = string
  description = "Default admin username for htpasswd auth (only used when auth_method = htpasswd and htpasswd_content is empty — i.e. the auto-generated path)."
  default     = "platforma"
}

# =============================================================================
# Authentication
# =============================================================================
# Two methods are supported (mirrors AWS CloudFormation):
#   - htpasswd: file-based local auth. Either auto-generated (testing only —
#     a random password lands in Secret Manager) or user-supplied bcrypted
#     content (production single-team).
#   - ldap: corporate directory integration. Pick direct-bind OR search-bind.
# =============================================================================

variable "auth_method" {
  type        = string
  description = "Authentication method: 'htpasswd' (local, file-based) or 'ldap' (corporate directory)."
  default     = "htpasswd"

  validation {
    condition     = contains(["htpasswd", "ldap"], var.auth_method)
    error_message = "auth_method must be one of: htpasswd, ldap."
  }
}

variable "htpasswd_content" {
  type        = string
  description = "htpasswd file content (one or more 'username:bcrypt-hash' lines). Generate with 'htpasswd -nB <user>'. Empty = auto-generate a random password for admin_username and store it in Secret Manager — TESTING ONLY (the password ends up in Terraform state). Production deployments should provide pre-bcrypted content."
  default     = ""
  sensitive   = true
}

variable "ldap_server" {
  type        = string
  description = "LDAP server URL (e.g. ldaps://ldap.example.com:636). LDAPS strongly recommended. Required when auth_method = ldap."
  default     = ""
}

variable "ldap_start_tls" {
  type        = bool
  description = "Enable StartTLS on the LDAP connection (only meaningful for plain ldap:// URLs; LDAPS is already TLS)."
  default     = false
}

variable "ldap_bind_dn" {
  type        = string
  description = "Direct-bind DN template — e.g. 'cn=%u,ou=users,dc=example,dc=com'. Set this OR ldap_search_rules; direct bind is simpler when usernames map predictably to DNs."
  default     = ""
}

variable "ldap_search_rules" {
  type        = list(string)
  description = "Search-bind rules — each entry 'filter|baseDN' (e.g. '(uid=%u)|ou=users,dc=example,dc=com'). Multiple entries are tried in order; first match wins. Set this OR ldap_bind_dn."
  default     = []
}

variable "ldap_search_user" {
  type        = string
  description = "DN of the service account used to perform search queries (required when ldap_search_rules is set)."
  default     = ""
}

variable "ldap_search_password" {
  type        = string
  description = "Password for ldap_search_user."
  default     = ""
  sensitive   = true
}

# =============================================================================
# Data libraries
# =============================================================================

variable "enable_demo_data_library" {
  type        = bool
  description = "Mount MiLaboratories' public demo data library (public GCS bucket with sample bioinformatics datasets) as a read-only data source visible in the Desktop App. Enabled by default — set to false to deploy without it."
  default     = true
}

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
  description = <<-EOT
    External read-only data libraries shown in the Desktop App. Each entry:
      name       — display name (lowercase alphanumeric + dash)
      type       — "gcs" or "s3"
      bucket     — bucket name
      prefix     — optional path prefix within the bucket
    GCS (type="gcs"):
      project_id — bucket's project; same-project = uses Workload Identity (no keys needed);
                   cross-project = grant Platforma server SA roles/storage.objectViewer on the
                   bucket beforehand (done outside this module).
    S3 (type="s3"):
      region            — AWS region (required for AWS S3)
      endpoint          — S3-compatible custom endpoint (MinIO, Ceph). Empty = AWS S3.
      external_endpoint — public URL the Desktop App should use (if different from endpoint)
      access_key        — IAM access key (for AWS S3 or HMAC for cross-project GCS)
      secret_key        — IAM secret key
    Leave access_key/secret_key empty for same-project GCS (Workload Identity).
  EOT
}

variable "platforma_image_override" {
  type        = string
  description = "Override Platforma container image (full repository:tag, e.g. 'quay.io/milaboratories/platforma:3.4.0'). Empty = use chart default."
  default     = ""
}

variable "deploy_platforma" {
  type        = bool
  description = "Deploy the Platforma application via Helm. Set to false to install only infrastructure + cluster controllers (Kueue, AppWrapper) — useful for testing the infra layer in isolation."
  default     = true
}

# =============================================================================
# Quota auto-request
# =============================================================================

variable "enable_quota_auto_request" {
  type        = bool
  description = "Submit quota-increase requests via google_cloud_quotas_quota_preference based on the deployment_size preset. Small bumps auto-approve in seconds; larger requests (xlarge tier and above) typically need human review (24-72h). Set to false to manage quotas manually."
  default     = true
}

variable "contact_email" {
  type        = string
  description = "Email for GCP to send quota approval/rejection notifications. Required when enable_quota_auto_request = true."
  default     = ""
}

variable "skip_quota_requests" {
  type        = list(string)
  description = "Quota request keys to skip even when enable_quota_auto_request = true. Use when a project already has existing user-managed QuotaPreference records for the same (service, quota_id, dimensions) — Cloud Quotas API rejects duplicate creates and offers no DELETE. Valid keys: cpus_global, n2d_cpus_region, pd_ssd_region, instances_region, filestore_zonal_region."
  default     = []
}
