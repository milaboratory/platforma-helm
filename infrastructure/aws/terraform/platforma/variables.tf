# =============================================================================
# Platforma module variables
# =============================================================================
# Deploys the in-cluster controllers (Kueue, AppWrapper, Cluster Autoscaler,
# and — when ingress is on — the AWS Load Balancer Controller and External DNS)
# and the Platforma Helm release. Applied AFTER infra.
#
# The shared identifiers below (region, cluster_name, platforma_namespace,
# helm_release_name, deployment_size, enable_gpu, ingress_enabled, domain_name,
# route53_zone_id) MUST match the values passed to infra: the IRSA
# trust policies, ECR cache prefix, ACM cert, and Kueue quotas were all wired up
# there against these exact values. The module discovers the cluster, IAM roles,
# EFS, and ACM cert by name/tag; only s3_bucket_name is passed in, since the
# infra module's auto-generated bucket name carries a random suffix.
# =============================================================================

# -----------------------------------------------------------------------------
# Shared identifiers — must match infra
# -----------------------------------------------------------------------------

variable "region" {
  type        = string
  description = "AWS region the cluster runs in. Must match infra."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. Used to discover the cluster and the IRSA roles (named <cluster>-<region>-*-irsa) and to build the ECR pull-through registry. Must match infra."
  default     = "platforma-cluster"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,24}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, 1-25 chars, starting with a letter or digit."
  }
}

variable "platforma_namespace" {
  type        = string
  description = "Kubernetes namespace for Platforma and its controllers. Must match infra (the IRSA trust policies are scoped to service accounts in this namespace)."
  default     = "platforma"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.platforma_namespace))
    error_message = "platforma_namespace must be a valid Kubernetes namespace (lowercase, digits, hyphens, starts with a letter, max 63 chars)."
  }
}

variable "helm_release_name" {
  type        = string
  description = "Helm release name for Platforma. The server service account is <helm_release_name> and the jobs service account <helm_release_name>-jobs; IRSA trust policies are scoped to those names. Must match infra."
  default     = "platforma"
}

variable "deployment_size" {
  type        = string
  description = "Cluster sizing profile. Selects the Kueue ClusterQueue quotas (see presets.tf). Must match infra so quotas line up with node-group MaxSize."
  default     = "small"

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.deployment_size)
    error_message = "deployment_size must be one of: small, medium, large, xlarge."
  }
}

variable "enable_gpu" {
  type        = bool
  description = "Enable the GPU Kueue pool. Must match infra (which provisions the GPU node groups). With no GPU node groups, GPU jobs stay Pending."
  default     = true
}

# -----------------------------------------------------------------------------
# Ingress / DNS — must match infra
# -----------------------------------------------------------------------------

variable "ingress_enabled" {
  type        = bool
  description = "Deploy the ALB ingress + AWS Load Balancer Controller + External DNS and enable the Platforma ingress. When true, domain_name and route53_zone_id are required and an ISSUED ACM cert for domain_name must exist (infra creates it). Must match infra."
  default     = true
}

variable "domain_name" {
  type        = string
  description = "Fully-qualified domain for the Platforma endpoint (e.g. platforma.example.com). Sets the ingress host and selects the ACM certificate. Required when ingress_enabled = true."
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\\.[a-zA-Z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid domain name (e.g. platforma.example.com) or empty."
  }
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 hosted zone ID controlling domain_name. External DNS is scoped to this zone (--zone-id-filter). Required when ingress_enabled = true."
  default     = ""
}

# -----------------------------------------------------------------------------
# Infra hand-off — the one value the module cannot derive by name
# -----------------------------------------------------------------------------

variable "s3_bucket_name" {
  type        = string
  description = "Primary S3 bucket (Platforma main storage). Take it from the infra module: `terraform -chdir=../infra output -raw s3_bucket_name`. Required because the auto-generated name carries a random suffix and cannot be reconstructed from cluster_name."

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9.-]{1,61}[a-z0-9])?$", var.s3_bucket_name))
    error_message = "s3_bucket_name must be a valid S3 bucket name (lowercase, digits, hyphens, periods, 3-63 chars)."
  }
}

# -----------------------------------------------------------------------------
# Platforma release
# -----------------------------------------------------------------------------

variable "deploy_platforma" {
  type        = bool
  description = "Deploy the Platforma Helm release. Set false to deploy only the controllers (Kueue, AppWrapper, Cluster Autoscaler, ALB, External DNS) — useful for staging infra before the first app rollout."
  default     = true
}

variable "chart_version" {
  type        = string
  description = "Platforma Helm chart version to pull from the OCI registry. Ignored when chart_local_path is set."
  default     = "3.5.0"
}

variable "chart_repository" {
  type        = string
  description = "OCI reference for the Platforma chart (without the version). Pinned to the official MiLaboratories registry; override only to pull from a mirror or private ECR."
  default     = "oci://ghcr.io/milaboratory/platforma-helm/platforma"
}

variable "chart_local_path" {
  type        = string
  description = "Path to a local Platforma chart directory or .tgz. When set, it overrides chart_repository/chart_version (used for chart development or air-gapped installs)."
  default     = ""
}

variable "platforma_image" {
  type        = string
  description = "Override the Platforma container image (repository:tag). Empty = use the chart default. Mirrors the CloudFormation PlatformaImage parameter."
  default     = ""
}

variable "license_key" {
  type        = string
  sensitive   = true
  description = "Platforma license key (MI_LICENSE). Stored in the platforma-license Secret. Required when deploy_platforma = true unless license_secret_name points at a pre-existing secret."
  default     = ""
}

variable "license_secret_name" {
  type        = string
  description = "Name of a pre-existing Secret holding the license under key MI_LICENSE. Empty = create the platforma-license Secret from license_key."
  default     = ""
}

# -----------------------------------------------------------------------------
# Authentication — htpasswd (default) or LDAP. Mirrors CF AuthMethod.
# -----------------------------------------------------------------------------

variable "auth_method" {
  type        = string
  description = "Authentication method: htpasswd or ldap. htpasswd auto-generates a single 'platforma' user (password stored in SSM) unless htpasswd_content is supplied."
  default     = "htpasswd"

  validation {
    condition     = contains(["htpasswd", "ldap"], var.auth_method)
    error_message = "auth_method must be one of: htpasswd, ldap."
  }
}

variable "htpasswd_content" {
  type        = string
  sensitive   = true
  description = "htpasswd file content (one 'user:hash' line per user; bcrypt hashes, e.g. from `htpasswd -nB user`). Empty + auth_method=htpasswd auto-generates a single 'platforma' user with a random password stored in SSM at /<cluster>/platforma/users-password."
  default     = ""
}

variable "ldap_server" {
  type        = string
  description = "LDAP server URL (ldap:// or ldaps://). Required when auth_method = ldap."
  default     = ""
}

variable "ldap_start_tls" {
  type        = bool
  description = "Enable LDAP StartTLS. Forced false for ldaps:// servers (already encrypted)."
  default     = false
}

variable "ldap_bind_dn" {
  type        = string
  description = "LDAP bind DN template for user authentication (optional)."
  default     = ""
}

variable "ldap_search_user" {
  type        = string
  description = "LDAP service-account DN for user search (optional)."
  default     = ""
}

variable "ldap_search_password" {
  type        = string
  sensitive   = true
  description = "Password for ldap_search_user (optional)."
  default     = ""
}

variable "ldap_search_rules" {
  type        = list(string)
  description = "LDAP search rules (optional). Each entry is one rule string."
  default     = []
}

# -----------------------------------------------------------------------------
# Data libraries — pass the SAME value given to infra. Libraries
# without access_key use IRSA (infra granted the platforma roles bucket read);
# libraries with access_key are materialised here as K8s Secrets.
# -----------------------------------------------------------------------------

variable "data_libraries" {
  type = list(object({
    name              = string
    bucket            = string
    prefix            = optional(string, "")
    region            = optional(string, "")
    endpoint          = optional(string, "")
    external_endpoint = optional(string, "")
    access_key        = optional(string, "")
    secret_key        = optional(string, "")
  }))
  default     = []
  description = "External read-only S3 data libraries exposed in the Desktop App. Pass the same list given to infra."

  validation {
    condition     = alltrue([for lib in var.data_libraries : (lib.access_key == "") == (lib.secret_key == "")])
    error_message = "Each data library must set both access_key and secret_key, or neither (use IRSA)."
  }

  validation {
    condition     = alltrue([for lib in var.data_libraries : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", lib.name))])
    error_message = "Each data library name must be a valid Kubernetes Secret name component (lowercase, digits, hyphens, starts/ends alphanumeric) — it is used to name the credentials Secret."
  }
}

variable "enable_demo_data_library" {
  type        = bool
  description = "Add MiLaboratories' read-only demo data library (milabs-demo-data). Uses MiLaboratories-owned, cross-account credentials baked into the chart values — not your IRSA roles. Mirrors CF EnableDemoLibrary (default true)."
  default     = true
}
