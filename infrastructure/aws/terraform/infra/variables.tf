# =============================================================================
# Infra module variables
# =============================================================================
# Provisions: VPC (optional), EKS cluster + node groups, IAM/IRSA roles, EFS,
# S3, ECR pull-through cache, ACM certificate. Mirrors the parameters of
# cloudformation-eks-1-35.yaml. Pass the shared identifiers (region,
# cluster_name, platforma_namespace, helm_release_name, deployment_size) to the
# platforma module too so K8s service-account names line up with the IRSA trust
# policies declared here.
# =============================================================================

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------

variable "region" {
  type        = string
  description = "AWS region to deploy into (e.g. eu-central-1). GPU node groups require a region with g6/g6e availability."
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster name. The ECR pull-through cache prefix (quay-<cluster_name>) and auto-generated S3 bucket name derive from this, so the 25-char lowercase constraint is load-bearing."
  default     = "platforma-cluster"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,24}$", var.cluster_name))
    error_message = "cluster_name must be lowercase alphanumeric with hyphens, 1-25 chars, starting with a letter or digit."
  }
}

variable "platforma_namespace" {
  type        = string
  description = "Kubernetes namespace for Platforma and its controllers. Used in IRSA trust policies (the K8s service accounts platforma, platforma-jobs, cluster-autoscaler, aws-load-balancer-controller, external-dns live here). Pass the same value to the platforma module."
  default     = "platforma"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,61}[a-z0-9])?$", var.platforma_namespace))
    error_message = "platforma_namespace must be a valid Kubernetes namespace (lowercase, digits, hyphens, starts with a letter, max 63 chars)."
  }
}

variable "helm_release_name" {
  type        = string
  description = "Helm release name for Platforma. The server service account is named <helm_release_name> and the jobs service account <helm_release_name>-jobs; IRSA trust policies are scoped to those names, so this must match the value passed to the platforma module."
  default     = "platforma"
}

variable "deployment_size" {
  type        = string
  description = "Cluster sizing profile. Controls node-group MaxSize per pool, GPU node counts, and the Kueue ClusterQueue quotas the platforma module derives. All sizes share the same max single-job size (62 vCPU / 484Gi)."
  default     = "small"

  validation {
    condition     = contains(["small", "medium", "large", "xlarge"], var.deployment_size)
    error_message = "deployment_size must be one of: small, medium, large, xlarge."
  }
}

variable "system_node_az" {
  type        = string
  description = "Availability-zone suffix (a, b, or c) for the system node group. Platforma's database and log EBS volumes are bound to a single AZ, so the system node group is pinned there. For new deployments 'a' is fine; for existing ones match the AZ of the platforma-database volume."
  default     = "a"

  validation {
    condition     = contains(["a", "b", "c"], var.system_node_az)
    error_message = "system_node_az must be one of: a, b, c."
  }
}

variable "enable_gpu" {
  type        = bool
  description = "Provision GPU node groups (g6f/g6e, scale-from-zero, no cost when idle). Set false in regions without GPU availability (e.g. eu-west-2, eu-west-3, ap-south-1) or to skip GPU entirely."
  default     = true
}

variable "cluster_admin_principal_arns" {
  type        = list(string)
  description = "Additional IAM principal ARNs (roles/users) to grant cluster-admin via EKS access entries. The principal that runs `terraform apply` is already admin via bootstrap_cluster_creator_admin_permissions; only set this when a DIFFERENT principal (e.g. a CI role applying platforma) must reach the cluster API. Use the role/user ARN, not an assumed-role session ARN."
  default     = []
}

# -----------------------------------------------------------------------------
# Networking — CreateNewVpc toggle (mirrors CF). Leave vpc_id empty to create a
# new VPC; otherwise supply exactly 3 private (and 3 public) subnet IDs, one per
# AZ. 3 subnets are required: EFS creates one mount target per AZ and EKS
# spreads nodes across AZs.
# -----------------------------------------------------------------------------

variable "vpc_id" {
  type        = string
  description = "Existing VPC ID to deploy into. Empty = create a new VPC. When set, private_subnet_ids (and public_subnet_ids for the ALB) are required."
  default     = ""

  validation {
    condition     = var.vpc_id == "" || can(regex("^vpc-[a-f0-9]{8,17}$", var.vpc_id))
    error_message = "vpc_id must be empty or a valid VPC ID (e.g. vpc-0123456789abcdef0)."
  }
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the new VPC (ignored when vpc_id is set)."
  default     = "10.0.0.0/16"
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Exactly 3 existing private subnet IDs (one per AZ). Required when vpc_id is set; leave empty when creating a new VPC. Worker nodes and EFS mount targets live here."
  default     = []

  validation {
    condition     = length(var.private_subnet_ids) == 0 || length(var.private_subnet_ids) == 3
    error_message = "private_subnet_ids must contain exactly 3 subnet IDs (one per AZ), or be empty when creating a new VPC."
  }
}

variable "public_subnet_ids" {
  type        = list(string)
  description = "Exactly 3 existing public subnet IDs (one per AZ) for the internet-facing ALB. Required when vpc_id is set; leave empty when creating a new VPC."
  default     = []

  validation {
    condition     = length(var.public_subnet_ids) == 0 || length(var.public_subnet_ids) == 3
    error_message = "public_subnet_ids must contain exactly 3 subnet IDs (one per AZ), or be empty when creating a new VPC."
  }
}

# -----------------------------------------------------------------------------
# Storage
# -----------------------------------------------------------------------------

variable "s3_bucket_name" {
  type        = string
  description = "Primary S3 bucket name (Platforma main storage). Empty = auto-generate platforma-<cluster>-<random>."
  default     = ""

  validation {
    condition     = var.s3_bucket_name == "" || can(regex("^[a-z0-9]([a-z0-9.-]{1,61}[a-z0-9])?$", var.s3_bucket_name))
    error_message = "s3_bucket_name must be empty or a valid S3 bucket name (lowercase, digits, hyphens, periods, 3-63 chars)."
  }
}

variable "s3_force_destroy" {
  type        = bool
  description = "Allow terraform destroy to delete the primary S3 bucket even when it still holds objects. DEFAULT FALSE — the bucket holds user result data and is retained on destroy by default, matching the CloudFormation Retain policy."
  default     = false
}

# -----------------------------------------------------------------------------
# Ingress / DNS / TLS — Route53 + ACM. Ingress is on by default because the
# Desktop App connects over TLS. Set ingress_enabled = false only for
# infra-only smoke tests (no cert, no DNS); the platforma module's ingress is
# gated on the same flag.
# -----------------------------------------------------------------------------

variable "ingress_enabled" {
  type        = bool
  description = "Provision the ACM certificate (DNS-validated via Route53) and enable the ALB ingress. When true, domain_name and route53_zone_id are required."
  default     = true
}

variable "domain_name" {
  type        = string
  description = "Fully-qualified domain for the Platforma endpoint (e.g. platforma.example.com). An ACM cert is issued and validated via Route53; External DNS manages the A record. Required when ingress_enabled = true."
  default     = ""

  validation {
    condition     = var.domain_name == "" || can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*\\.[a-zA-Z]{2,}$", var.domain_name))
    error_message = "domain_name must be a valid domain name (e.g. platforma.example.com) or empty."
  }
}

variable "route53_zone_id" {
  type        = string
  description = "Route53 hosted zone ID controlling domain_name. Used for ACM DNS validation and External DNS. Required when ingress_enabled = true."
  default     = ""
}

# -----------------------------------------------------------------------------
# Data libraries — IAM only at the infra layer. The infra module grants the
# platforma runtime IRSA roles read access to library buckets accessed via IRSA
# (no access_key). The platforma module materialises K8s Secrets for libraries
# that carry explicit credentials. Pass the same value to both modules.
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
  description = "External read-only S3 data libraries. Entries without access_key use IRSA (bucket must be in this account) and get bucket read access granted to the platforma roles here. Entries with access_key are materialised as K8s Secrets by the platforma module."

  validation {
    condition     = alltrue([for lib in var.data_libraries : (lib.access_key == "") == (lib.secret_key == "")])
    error_message = "Each data library must set both access_key and secret_key, or neither (use IRSA)."
  }
}

# enable_demo_data_library lives in the platforma module only: the demo dataset
# is a MiLaboratories-owned, cross-account bucket accessed with embedded
# read-only credentials (a K8s Secret), not via IRSA — so the infra layer has
# nothing to grant for it.
