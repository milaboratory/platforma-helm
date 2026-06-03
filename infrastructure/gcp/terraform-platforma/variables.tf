# =============================================================================
# Platforma module variables
# =============================================================================
# Applied AFTER the infra module. Reads cluster/storage/IAM details via data
# sources keyed on the identifiers below — pass the same values you passed to
# the infra module (project_id, cluster_name, zone, etc.) plus the discovered
# bucket/filestore names from the infra module's outputs.
# =============================================================================

# -----------------------------------------------------------------------------
# Identifiers — match the infra module
# -----------------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "GCP project ID. Must match the infra module."
}

variable "region" {
  type        = string
  description = "GCP region. Must match the infra module."
  default     = "europe-west1"
}

variable "zone_suffix" {
  type        = string
  description = "Zone suffix (a/b/c/d). Must match the infra module."
  default     = "b"

  validation {
    condition     = can(regex("^[a-d]$", var.zone_suffix))
    error_message = "zone_suffix must be one of: a, b, c, d."
  }
}

variable "cluster_name" {
  type        = string
  description = "GKE cluster name. Must match the infra module."
  default     = "platforma-cluster"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,24}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, 1-25 chars."
  }
}

variable "platforma_namespace" {
  type        = string
  description = "Kubernetes namespace for Platforma. Must match the namespace bound by the infra module's Workload Identity bindings."
  default     = "platforma"
}

variable "helm_release_name" {
  type        = string
  description = "Helm release name. Must match the infra module (it computes K8s SA names from this for Workload Identity bindings)."
  default     = "platforma"
}

variable "deployment_size" {
  type        = string
  description = "Cluster sizing profile. Must match the infra module — drives Kueue ClusterQueue sizing here, node-pool maxes there."
  default     = "small"

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.deployment_size)
    error_message = "deployment_size must be one of: small, medium, large, xlarge."
  }
}

# -----------------------------------------------------------------------------
# Outputs from the infra module — install.sh threads these through from
# `gcloud infra-manager deployments describe <infra-deployment> ...`.
# -----------------------------------------------------------------------------

variable "gcs_bucket" {
  type        = string
  description = "Primary GCS bucket name (from infra module output)."
}

variable "filestore_instance_name" {
  type        = string
  description = "Workspace Filestore instance name (from infra module output)."
}

# -----------------------------------------------------------------------------
# Ingress / TLS — must match the infra module's flag and domain.
# -----------------------------------------------------------------------------

variable "ingress_enabled" {
  type        = bool
  description = "Pass-through of infra module's ingress_enabled. Gates the Gateway/HTTPRoute/HealthCheckPolicy in this module."
  default     = false
}

variable "domain_name" {
  type        = string
  description = "FQDN for HTTPRoute hostname rule. Required when ingress_enabled = true."
  default     = ""
}

# -----------------------------------------------------------------------------
# Cluster controllers — Kueue + AppWrapper versions and integrity check
# -----------------------------------------------------------------------------

variable "kueue_version" {
  type        = string
  description = "Kueue Helm chart version."
  default     = "0.16.1"
}

variable "appwrapper_version" {
  type        = string
  description = "AppWrapper release tag (used in install.yaml URL). Bumping requires updating appwrapper_install_yaml_sha256 below."
  default     = "v1.2.0"
}

variable "appwrapper_install_yaml_sha256" {
  type        = string
  description = "Expected SHA-256 of the AppWrapper install.yaml manifest pulled from the upstream release URL."
  default     = "aabb84a8719248c1dfaa6516f194dce559043237657cc697823f61ebeeaf9024"

  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.appwrapper_install_yaml_sha256))
    error_message = "appwrapper_install_yaml_sha256 must be a 64-character lowercase hex SHA-256."
  }
}

# -----------------------------------------------------------------------------
# Kueue per-job + queue caps (overrides; defaults derive from presets.tf)
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

variable "batch_pool_max_nodes_overrides" {
  type = map(number)
  description = <<-EOT
    DEPRECATED — no-op since the Node Auto-Provisioning migration. Batch
    capacity is now governed by a cluster-wide envelope (batch_capacity in
    presets.tf, NAP resource_limits in terraform-infra/gke.tf). Override
    via var.kueue_batch_queue_cpu / var.kueue_batch_queue_memory instead.
    Variable kept for tfvars backwards-compatibility; will be removed in
    a future release.
  EOT
  default = {}
}

variable "ui_pool_max_nodes" {
  type        = number
  description = "Match the infra module for symmetric tfvars; not used by this module directly."
  default     = null
}

variable "workspace_capacity_gb" {
  type        = number
  description = "Match the infra module for symmetric tfvars; not used by this module directly."
  default     = null
}

# -----------------------------------------------------------------------------
# Platforma application
# -----------------------------------------------------------------------------

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

variable "helm_chart_repository" {
  type        = string
  description = "Override the source of the Platforma Helm chart with an OCI registry URL. Empty (default) uses the local chart bundled by install.sh at <module>/platforma."
  default     = ""
}

variable "platforma_image_override" {
  type        = string
  description = "Override Platforma container image (full repository:tag). Empty = use chart default."
  default     = ""
}

variable "deploy_platforma" {
  type        = bool
  description = "Deploy the Platforma application via Helm. Set to false to install only Kueue + AppWrapper — useful for testing the infra layer in isolation."
  default     = true
}

variable "admin_username" {
  type        = string
  description = "Default admin username for htpasswd auth (auto-generated path only)."
  default     = "platforma"
}

# -----------------------------------------------------------------------------
# Auth
# -----------------------------------------------------------------------------

variable "auth_method" {
  type        = string
  description = "Authentication method: 'htpasswd' (local) or 'ldap' (corporate directory)."
  default     = "htpasswd"

  validation {
    condition     = contains(["htpasswd", "ldap"], var.auth_method)
    error_message = "auth_method must be one of: htpasswd, ldap."
  }
}

variable "htpasswd_content" {
  type        = string
  description = "htpasswd file content. Empty = auto-generate a random password and store it in Secret Manager (testing only)."
  default     = ""
  sensitive   = true
}

variable "ldap_server" {
  type        = string
  description = "LDAP server URL (e.g. ldaps://ldap.example.com:636)."
  default     = ""
}

variable "ldap_start_tls" {
  type        = bool
  description = "Enable StartTLS on the LDAP connection."
  default     = false
}

variable "ldap_bind_dn" {
  type        = string
  description = "Direct-bind DN template."
  default     = ""
}

variable "ldap_search_rules" {
  type        = list(string)
  description = "Search-bind rules."
  default     = []
}

variable "ldap_search_user" {
  type        = string
  description = "DN of the service account used to perform search queries."
  default     = ""
}

variable "ldap_search_password" {
  type        = string
  description = "Password for ldap_search_user."
  default     = ""
  sensitive   = true
}

# -----------------------------------------------------------------------------
# Data libraries
# -----------------------------------------------------------------------------

variable "enable_demo_data_library" {
  type        = bool
  description = "Mount MiLaboratories' public demo data library."
  default     = true
}

variable "data_libraries" {
  type = list(object({
    name              = string
    type              = string
    bucket            = string
    prefix            = optional(string, "")
    project_id        = optional(string, "")
    region            = optional(string, "")
    endpoint          = optional(string, "")
    external_endpoint = optional(string, "")
    access_key        = optional(string, "")
    secret_key        = optional(string, "")
  }))
  default     = []
  description = "External read-only data libraries. Same value as passed to the infra module — that module grants GCS IAM, this one materialises K8s Secrets for S3 entries with credentials and renders the chart's dataSources values."
}
