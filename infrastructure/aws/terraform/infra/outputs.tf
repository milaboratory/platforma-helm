# =============================================================================
# Outputs — identifiers the platforma module and operators consume
# =============================================================================
# The platforma module discovers most of these by name via data sources (it is
# applied separately), so it only needs the shared identifiers (cluster_name,
# region, namespace, helm_release_name). These outputs are for humans and for
# operators who prefer to wire the two modules by passing outputs as variables.
# =============================================================================

output "cluster_name" {
  description = "EKS cluster name. Configure kubectl: aws eks update-kubeconfig --name <name> --region <region>."
  value       = aws_eks_cluster.this.name
}

output "region" {
  description = "AWS region the cluster is deployed in."
  value       = var.region
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_oidc_provider_arn" {
  description = "IAM OIDC provider ARN backing IRSA."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "vpc_id" {
  description = "VPC the cluster runs in (created or bring-your-own)."
  value       = local.resolved_vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs hosting the nodes and EFS mount targets."
  value       = local.resolved_private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs for the internet-facing ALB (empty if none)."
  value       = local.resolved_public_subnet_ids
}

output "s3_bucket_name" {
  description = "Primary S3 bucket (Platforma main storage)."
  value       = aws_s3_bucket.main.bucket
}

output "efs_file_system_id" {
  description = "EFS file system ID for the shared workspace."
  value       = aws_efs_file_system.workspace.id
}

output "ecr_pl_containers_repository_url" {
  description = "ECR pull-through cache repository URL for Platforma images (set as the default Docker registry)."
  value       = aws_ecr_repository.pl_containers.repository_url
}

# --- IRSA role ARNs (annotate the matching service accounts) -----------------
output "platforma_role_arn" {
  description = "IRSA role ARN for the platforma service account."
  value       = aws_iam_role.platforma.arn
}

output "platforma_jobs_role_arn" {
  description = "IRSA role ARN for the platforma-jobs service account."
  value       = aws_iam_role.platforma_jobs.arn
}

output "autoscaler_role_arn" {
  description = "IRSA role ARN for the cluster-autoscaler service account."
  value       = aws_iam_role.autoscaler.arn
}

output "alb_controller_role_arn" {
  description = "IRSA role ARN for aws-load-balancer-controller (null when ingress disabled)."
  value       = one(aws_iam_role.alb_controller[*].arn)
}

output "external_dns_role_arn" {
  description = "IRSA role ARN for external-dns (null when ingress disabled)."
  value       = one(aws_iam_role.external_dns[*].arn)
}

output "acm_certificate_arn" {
  description = "Validated ACM certificate ARN for the ALB ingress (null when ingress disabled)."
  value       = one(aws_acm_certificate.this[*].arn)
}
