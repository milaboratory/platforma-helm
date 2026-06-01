# =============================================================================
# Discovery — find what infra created
# =============================================================================
# Everything here is resolved at plan time (live AWS API calls), so the
# kubernetes/helm/kubectl providers can be configured from concrete values and
# the IRSA role ARNs / EFS id / cert ARN flow straight into the Helm values.
# This means `terraform plan` for this module needs valid AWS credentials and an
# already-applied infra. Names are deterministic
# (<cluster>-<region>-*-irsa, <cluster>-workspace), so discovery is by name/tag.
# =============================================================================

data "aws_caller_identity" "current" {}

# Cluster — also consumed by providers.tf for kubernetes/helm/kubectl auth.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# EFS shared workspace — discovered by the stable creation_token infra sets.
data "aws_efs_file_system" "workspace" {
  creation_token = "${var.cluster_name}-workspace"
}

# IRSA roles always present.
data "aws_iam_role" "platforma" {
  name = "${var.cluster_name}-${var.region}-platforma-irsa"
}

data "aws_iam_role" "platforma_jobs" {
  name = "${var.cluster_name}-${var.region}-platforma-jobs-irsa"
}

data "aws_iam_role" "autoscaler" {
  name = "${var.cluster_name}-${var.region}-autoscaler-irsa"
}

# IRSA roles present only when ingress is enabled (infra gates them the same way).
data "aws_iam_role" "alb_controller" {
  count = var.ingress_enabled ? 1 : 0
  name  = "${var.cluster_name}-${var.region}-alb-controller-irsa"
}

data "aws_iam_role" "external_dns" {
  count = var.ingress_enabled ? 1 : 0
  name  = "${var.cluster_name}-${var.region}-external-dns-irsa"
}

# Validated ACM certificate for the ALB ingress, discovered by domain name.
data "aws_acm_certificate" "this" {
  count       = var.ingress_enabled ? 1 : 0
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

locals {
  account_id = data.aws_caller_identity.current.account_id

  # Per-cluster ECR pull-through cache repository for Platforma images. Matches
  # the repository infra pre-creates; set as Platforma's default
  # Docker registry so workflow containers pull through the same-region cache.
  ecr_registry = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com/quay-${var.cluster_name}/milaboratories/pl-containers"

  efs_file_system_id = data.aws_efs_file_system.workspace.file_system_id

  platforma_role_arn      = data.aws_iam_role.platforma.arn
  platforma_jobs_role_arn = data.aws_iam_role.platforma_jobs.arn
  autoscaler_role_arn     = data.aws_iam_role.autoscaler.arn
  alb_controller_role_arn = one(data.aws_iam_role.alb_controller[*].arn)
  external_dns_role_arn   = one(data.aws_iam_role.external_dns[*].arn)

  acm_certificate_arn = one(data.aws_acm_certificate.this[*].arn)
}
