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
# In-cluster controllers — AppWrapper overrides
# -----------------------------------------------------------------------------

variable "appwrapper_image" {
  type        = string
  description = <<-EOT
    Container image for the AppWrapper controller, substituted into the upstream
    install.yaml. Defaults to our patched build of v1.2.0.

    Upstream v1.2.0 fails a workload permanently when the controller reads back a
    Job it has just created through an informer cache that has not caught up:

      MissingComponent: Only found 0 deployed components, but was expecting 1

    The audit log shows jobs.create returning success ~100ms earlier, and in one
    case a second create returning ALREADY EXISTS 245ms later, so the controller
    cannot see its own write. Unlike the neighbouring FoundFailedPods branch,
    which waits out a FailureGracePeriod, this path takes no grace period and no
    retry, so a sub-second cache lag destroys a user job. It reaches users as a
    container exiting -1. Observed on two independent customer clusters, so it is
    not environment-specific, and it is not fixed in v1.2.2 (that release is
    dependency bumps and a CI matrix update; the code path is unchanged).

    Pinned by digest as well as tag: the SHA-256 check in controllers.tf covers
    the upstream YAML, not our registry, so a republished tag would otherwise
    swap the controller out from under a restarted pod with no configuration
    change. The digest is the multi-arch image index, so platform selection
    still works.

    Set to "" to use the upstream image from install.yaml unmodified. Once
    upstream ships a fix, drop this override and bump appwrapper_version instead.
  EOT
  default     = "public.ecr.aws/miresearch/pl-containers:appwrapper-v1.2.0-milab-6881@sha256:77fda74e30c6fd1bf8fb6c5c419ab9b92c82d9b8d32d9ca46fefb78338ede9a5"
}

variable "appwrapper_controller_memory_limit" {
  type        = string
  description = <<-EOT
    Memory limit for the AppWrapper controller, substituted into the upstream
    install.yaml. Upstream ships 128Mi, which leaves no headroom: the controller
    caches every AppWrapper, Job and Pod it watches, so footprint grows with the
    size of the queue rather than staying flat. Set to the upstream value to
    apply the manifest unchanged.
  EOT
  default     = "1Gi"
}

variable "appwrapper_controller_memory_request" {
  type        = string
  description = <<-EOT
    Memory request for the AppWrapper controller, substituted into the upstream
    install.yaml. Upstream ships 64Mi. Raised so the scheduler reserves a
    realistic amount and the controller is not placed on a node it will later
    contend for memory on.
  EOT
  default     = "256Mi"
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
  default     = "4.1.2"
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

variable "master_secret_ssm_parameter_name" {
  type        = string
  description = "Name of a pre-existing SSM SecureString parameter holding the Platforma master secret (chart security layer — DB encryption + session/resource signing). Required: pre-stage the parameter and value before apply. The latest version is read at apply time via the AWS provider; the value never travels through tfvars. SSM Parameter Store is the source of truth, so re-applies are stable and rotation is performed by overwriting the parameter out-of-band."
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

# -----------------------------------------------------------------------------
# Extra Platforma server args
# -----------------------------------------------------------------------------

variable "additional_extra_args" {
  type        = list(string)
  description = "Additional command-line flags appended to the Platforma server's extraArgs, after the flags this module always sets (--default-docker-registry). Each element is one whole argument, e.g. \"--some-flag=value\"."
  default     = []

  validation {
    condition     = alltrue([for arg in var.additional_extra_args : startswith(arg, "-")])
    error_message = "Each element of additional_extra_args must be a single flag starting with '-' (e.g. \"--flag=value\"); do not split a flag and its value across elements unless the server expects them separately."
  }
}
