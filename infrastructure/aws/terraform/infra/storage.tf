# =============================================================================
# Storage — EFS (shared workspace), S3 (primary), ECR pull-through cache
# =============================================================================
# Mirrors cloudformation-eks-1-35.yaml storage resources.
#
# Retention: CF marks EFS and S3 DeletionPolicy=Retain because both hold user
# data. Plain Terraform deletes managed resources on `terraform destroy`, so:
#   * S3 keeps a soft guard — force_destroy defaults false, so destroy fails
#     while the results bucket is non-empty (var.s3_force_destroy overrides).
#   * EFS has no content-based guard in the API. It IS destroyed by
#     `terraform destroy`. Add `lifecycle { prevent_destroy = true }` for
#     production, or snapshot/back up before tearing down.
# =============================================================================

# -----------------------------------------------------------------------------
# EFS shared workspace (RWX). One mount target per private subnet/AZ so every
# node can mount it. Reachable only from the cluster security group on NFS/2049.
# -----------------------------------------------------------------------------
resource "aws_security_group" "efs" {
  name        = "${var.cluster_name}-efs-sg"
  description = "Allow NFS traffic to Platforma EFS - ${var.cluster_name}"
  vpc_id      = local.resolved_vpc_id

  ingress {
    description     = "NFS from cluster nodes"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id]
  }

  tags = { Name = "${var.cluster_name}-efs-sg" }
}

resource "aws_efs_file_system" "workspace" {
  # Stable token (not a random one) so the platforma module can discover this
  # file system by name via data.aws_efs_file_system.creation_token.
  creation_token = "${var.cluster_name}-workspace"

  performance_mode = "generalPurpose"
  throughput_mode  = "elastic"
  encrypted        = true

  tags = { Name = "${var.cluster_name}-workspace" }
}

resource "aws_efs_mount_target" "workspace" {
  count = 3

  file_system_id  = aws_efs_file_system.workspace.id
  subnet_id       = local.resolved_private_subnet_ids[count.index]
  security_groups = [aws_security_group.efs.id]
}

# -----------------------------------------------------------------------------
# S3 primary storage. Name is caller-supplied or auto-generated
# platforma-<cluster>-<random>. SSE-S3 (AES256), all public access blocked,
# and TLS enforced via bucket policy.
# -----------------------------------------------------------------------------
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  s3_bucket_name = var.s3_bucket_name != "" ? var.s3_bucket_name : "platforma-${var.cluster_name}-${random_id.bucket_suffix.hex}"
}

resource "aws_s3_bucket" "main" {
  bucket        = local.s3_bucket_name
  force_destroy = var.s3_force_destroy
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "s3_main" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.main.arn, "${aws_s3_bucket.main.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "main" {
  bucket = aws_s3_bucket.main.id
  policy = data.aws_iam_policy_document.s3_main.json

  # The public access block must settle before a bucket policy referencing
  # Principal "*" is accepted.
  depends_on = [aws_s3_bucket_public_access_block.main]
}

# -----------------------------------------------------------------------------
# ECR pull-through cache for quay.io. Nodes pull Platforma images through this
# same-region cache (lower latency, less load on the upstream). The prefix is
# namespaced with the cluster name — AWS allows one rule per (account, region,
# prefix), so this lets multiple clusters share an account.
# -----------------------------------------------------------------------------
resource "aws_ecr_pull_through_cache_rule" "quay" {
  ecr_repository_prefix = "quay-${var.cluster_name}"
  upstream_registry_url = "quay.io"
}

# Pull-through auto-creates repositories on first pull; pre-create the main one
# so the 90-day expiry lifecycle policy is attached from the start.
resource "aws_ecr_repository" "pl_containers" {
  name         = "quay-${var.cluster_name}/milaboratories/pl-containers"
  force_delete = true

  depends_on = [aws_ecr_pull_through_cache_rule.quay]
}

resource "aws_ecr_lifecycle_policy" "pl_containers" {
  repository = aws_ecr_repository.pl_containers.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire images older than 90 days"
        selection = {
          tagStatus   = "any"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 90
        }
        action = { type = "expire" }
      }
    ]
  })
}
