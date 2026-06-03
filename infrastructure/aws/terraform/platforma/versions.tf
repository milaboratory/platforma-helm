# =============================================================================
# Provider requirements — platforma module
# =============================================================================
# This module runs all Kubernetes/Helm resources. It is applied AFTER
# infra creates the cluster; it discovers the cluster, IAM roles,
# EFS, and S3 via data sources at plan time (see data.tf), so the helm/
# kubernetes/kubectl providers can be configured from concrete values without
# the chicken-and-egg of referencing managed resources that don't exist yet.
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    # alekc/kubectl (not gavinbunney/kubectl) — actively maintained fork with
    # server-side-apply support, used to apply the multi-doc AppWrapper
    # install.yaml and the ProvisioningRequest CRD.
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # No backend block — customers wire their own. See the README.
}
