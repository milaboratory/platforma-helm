# =============================================================================
# Provider requirements — infra module
# =============================================================================
# This module provisions AWS cloud resources only (VPC, EKS, node groups,
# IAM/IRSA roles, EFS, S3, ECR pull-through cache, ACM). It does NOT run any
# kubectl/helm/kubernetes resources — those live in platforma, which
# reads this module's resources via data sources at plan time.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    # Used to fetch the EKS OIDC issuer's TLS thumbprint for the IAM OIDC
    # provider (IRSA). AWS no longer validates this thumbprint for EKS, but the
    # IAM API still requires a non-empty thumbprint_list on creation.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # No backend block — customers wire their own (S3 + DynamoDB lock is typical).
  # See backend.tf.example and the README.
}
