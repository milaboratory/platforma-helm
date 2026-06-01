# =============================================================================
# Provider configuration — kubernetes/helm/kubectl sourced via data sources
# =============================================================================
# The cluster already exists (infra applied first), so
# data.aws_eks_cluster.this (data.tf) returns concrete endpoint + CA at plan
# time. Auth uses the `aws eks get-token` exec plugin rather than the
# data.aws_eks_cluster_auth token: the controller + Platforma helm_releases can
# take well over 15 minutes, and the exec plugin mints a fresh token per call
# instead of baking a single short-lived token into the plan. Requires the AWS
# CLI v2 on the machine running Terraform (already a documented prerequisite).
# =============================================================================

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      "platforma.bio/cluster" = var.cluster_name
      "ManagedBy"             = "terraform"
    }
  }
}

locals {
  eks_exec = {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.region]
  }
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

  exec {
    api_version = local.eks_exec.api_version
    command     = local.eks_exec.command
    args        = local.eks_exec.args
  }
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)

    exec = {
      api_version = local.eks_exec.api_version
      command     = local.eks_exec.command
      args        = local.eks_exec.args
    }
  }
}

provider "kubectl" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  load_config_file       = false

  exec {
    api_version = local.eks_exec.api_version
    command     = local.eks_exec.command
    args        = local.eks_exec.args
  }
}
