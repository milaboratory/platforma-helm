# =============================================================================
# EKS cluster, OIDC provider, managed add-ons
# =============================================================================
# Mirrors cloudformation-eks-1-35.yaml: EksClusterRole, EksClusterLogGroup,
# EksCluster (1.35), OidcProvider, and the six EKS-managed add-ons. The cluster
# is ALWAYS Terraform-managed — the bring-your-own toggle in network.tf only
# affects networking, never the cluster itself.
# =============================================================================

# -----------------------------------------------------------------------------
# Cluster IAM role
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "eks_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-${var.region}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "cluster_eks" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# -----------------------------------------------------------------------------
# Control-plane log group. Created ahead of the cluster so EKS writes into a
# group with a defined 30-day retention rather than auto-creating a never-expiry
# one.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 30
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = "1.35"
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = local.cluster_subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = true
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # The principal running `terraform apply` becomes cluster admin. The
    # platforma module connects as that same principal via `aws eks get-token`,
    # so no explicit access entry is needed for the common single-principal
    # flow. Grant additional principals (CI roles, operators) via
    # var.cluster_admin_principal_arns below.
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "scheduler", "controllerManager"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_eks,
    aws_cloudwatch_log_group.cluster,
  ]
}

# -----------------------------------------------------------------------------
# OIDC provider for IRSA. The thumbprint is read from the issuer's TLS chain
# rather than hardcoded (CF pins 9e99a48a…; AWS no longer validates it for EKS
# issuers, but deriving it keeps the module correct if AWS ever rotates).
# -----------------------------------------------------------------------------
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = { Name = "${var.cluster_name}-oidc" }
}

locals {
  # Issuer URL without the https:// scheme — the form IRSA condition keys use
  # (<issuer>:sub / <issuer>:aud). Consumed by iam.tf.
  oidc_issuer = replace(aws_eks_cluster.this.identity[0].oidc[0].issuer, "https://", "")
}

# -----------------------------------------------------------------------------
# Extra cluster admins (optional). bootstrap_cluster_creator_admin_permissions
# already covers the apply principal; use this when a different principal (CI,
# another operator) must reach the API — e.g. when platforma is
# applied by a role other than the one that created the cluster.
# -----------------------------------------------------------------------------
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}

# -----------------------------------------------------------------------------
# Managed add-ons. ResolveConflicts=OVERWRITE on create and update: this module
# builds the cluster fresh, so OVERWRITE takes over the EKS self-managed
# defaults (vpc-cni, kube-proxy, coredns) for version governance.
#
# vpc-cni and kube-proxy install independent of nodes (nodes need vpc-cni to go
# Ready). coredns, the CSI drivers, and metrics-server run as pods, so they wait
# on the system node group to have capacity — mirrors CF's DependsOn.
# -----------------------------------------------------------------------------
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "efs_csi" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-efs-csi-driver"
  service_account_role_arn    = aws_iam_role.efs_csi.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "metrics-server"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.system]
}
