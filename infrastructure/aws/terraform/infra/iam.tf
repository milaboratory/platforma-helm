# =============================================================================
# IAM — node role + IRSA roles for the controllers and Platforma
# =============================================================================
# Mirrors cloudformation-eks-1-35.yaml IAM resources. Every IRSA trust policy
# federates the cluster OIDC provider (eks.tf) and is scoped to one
# namespace:serviceaccount pair. Role names embed cluster + region to stay
# unique across stacks sharing an account.
#
# ALB controller and External DNS roles are created only when ingress is
# enabled — they back controllers the platforma module installs only in that
# case (see var.ingress_enabled).
# =============================================================================

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Shared IRSA trust policies. One assume-role document per service account; the
# only difference between them is the `:sub` claim.
# -----------------------------------------------------------------------------
locals {
  irsa_service_accounts = {
    ebs_csi        = "kube-system:ebs-csi-controller-sa"
    efs_csi        = "kube-system:efs-csi-controller-sa"
    platforma      = "${var.platforma_namespace}:${var.helm_release_name}"
    platforma_jobs = "${var.platforma_namespace}:${var.helm_release_name}-jobs"
    autoscaler     = "${var.platforma_namespace}:cluster-autoscaler"
    alb            = "${var.platforma_namespace}:aws-load-balancer-controller"
    external_dns   = "${var.platforma_namespace}:external-dns"
  }

  # Data libraries accessed via IRSA (no embedded credentials). Their buckets
  # must be readable by the platforma runtime roles. Entries WITH access_key are
  # handled as K8s Secrets by the platforma module and need no IAM here.
  irsa_libraries = [for lib in var.data_libraries : lib if lib.access_key == ""]
}

data "aws_iam_policy_document" "irsa_assume" {
  for_each = local.irsa_service_accounts

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${each.value}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# -----------------------------------------------------------------------------
# Node group role. Nodes pull images through the per-cluster ECR pull-through
# cache (prefix quay-<cluster>); the inline policy is scoped to that prefix so
# stacks sharing an account don't grant each other cache writes.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "node_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-${var.region}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node_worker" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_readonly" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

data "aws_iam_policy_document" "node_ecr_pull_through" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:BatchImportUpstreamImage", "ecr:CreateRepository"]
    resources = ["arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/quay-${var.cluster_name}/*"]
  }
}

resource "aws_iam_role_policy" "node_ecr_pull_through" {
  name   = "ecr-pull-through-cache"
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node_ecr_pull_through.json
}

# -----------------------------------------------------------------------------
# CSI driver roles (kube-system). Add-ons in eks.tf attach these via
# service_account_role_arn.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-${var.region}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["ebs_csi"].json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "efs_csi" {
  name               = "${var.cluster_name}-${var.region}-efs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["efs_csi"].json
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

# -----------------------------------------------------------------------------
# Platforma runtime roles. The server (platforma) and jobs (platforma-jobs)
# service accounts get the same S3 access: read/write on the main bucket plus
# read on any IRSA data-library buckets.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "platforma_s3" {
  statement {
    sid       = "ListBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
    resources = [aws_s3_bucket.main.arn]
  }

  statement {
    sid    = "ReadWriteObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:GetObjectAttributes",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${aws_s3_bucket.main.arn}/*"]
  }

  dynamic "statement" {
    for_each = local.irsa_libraries
    content {
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
      resources = ["arn:aws:s3:::${statement.value.bucket}"]
    }
  }

  dynamic "statement" {
    for_each = local.irsa_libraries
    content {
      effect    = "Allow"
      actions   = ["s3:GetObject", "s3:GetObjectAttributes"]
      resources = ["arn:aws:s3:::${statement.value.bucket}/*"]
    }
  }
}

resource "aws_iam_role" "platforma" {
  name               = "${var.cluster_name}-${var.region}-platforma-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["platforma"].json
}

resource "aws_iam_role_policy" "platforma_s3" {
  name   = "platforma-s3-access"
  role   = aws_iam_role.platforma.id
  policy = data.aws_iam_policy_document.platforma_s3.json
}

resource "aws_iam_role" "platforma_jobs" {
  name               = "${var.cluster_name}-${var.region}-platforma-jobs-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["platforma_jobs"].json
}

resource "aws_iam_role_policy" "platforma_jobs_s3" {
  name   = "platforma-jobs-s3-access"
  role   = aws_iam_role.platforma_jobs.id
  policy = data.aws_iam_policy_document.platforma_s3.json
}

# -----------------------------------------------------------------------------
# Cluster Autoscaler. Describe across the account; scale only ASGs tagged for
# this cluster (eks:cluster-name).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "autoscaler" {
  name               = "${var.cluster_name}-${var.region}-autoscaler-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["autoscaler"].json
}

data "aws_iam_policy_document" "autoscaler" {
  statement {
    sid    = "DescribeResources"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ScaleNodeGroups"
    effect    = "Allow"
    actions   = ["autoscaling:SetDesiredCapacity", "autoscaling:TerminateInstanceInAutoScalingGroup"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/eks:cluster-name"
      values   = [var.cluster_name]
    }
  }
}

resource "aws_iam_role_policy" "autoscaler" {
  name   = "cluster-autoscaler"
  role   = aws_iam_role.autoscaler.id
  policy = data.aws_iam_policy_document.autoscaler.json
}

# -----------------------------------------------------------------------------
# AWS Load Balancer Controller (ingress only). Transcribed from the controller's
# canonical IAM policy as embedded in the CloudFormation template.
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "alb_controller" {
  statement {
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values   = ["elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "ec2:GetSecurityGroupsForVpc",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTrustStores",
      "elasticloadbalancing:DescribeListenerAttributes",
      "elasticloadbalancing:DescribeCapacityReservation",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "cognito-idp:DescribeUserPoolClient",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "iam:ListServerCertificates",
      "iam:GetServerCertificate",
      "waf-regional:GetWebACL",
      "waf-regional:GetWebACLForResource",
      "waf-regional:AssociateWebACL",
      "waf-regional:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
      "shield:CreateProtection",
      "shield:DeleteProtection",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:AuthorizeSecurityGroupIngress", "ec2:RevokeSecurityGroupIngress"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateSecurityGroup"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]

    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSecurityGroup"]
    }

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:CreateTags", "ec2:DeleteTags"]
    resources = ["arn:aws:ec2:*:*:security-group/*"]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DeleteSecurityGroup",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["elasticloadbalancing:CreateLoadBalancer", "elasticloadbalancing:CreateTargetGroup"]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
    ]
    resources = ["*"]
  }

  statement {
    effect  = "Allow"
    actions = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["true"]
    }

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect  = "Allow"
    actions = ["elasticloadbalancing:AddTags", "elasticloadbalancing:RemoveTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:listener/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener/app/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/net/*/*/*",
      "arn:aws:elasticloadbalancing:*:*:listener-rule/app/*/*/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyListenerAttributes",
      "elasticloadbalancing:ModifyCapacityReservation",
    ]
    resources = ["*"]

    condition {
      test     = "Null"
      variable = "aws:ResourceTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect  = "Allow"
    actions = ["elasticloadbalancing:AddTags"]
    resources = [
      "arn:aws:elasticloadbalancing:*:*:targetgroup/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/net/*/*",
      "arn:aws:elasticloadbalancing:*:*:loadbalancer/app/*/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "elasticloadbalancing:CreateAction"
      values   = ["CreateTargetGroup", "CreateLoadBalancer"]
    }

    condition {
      test     = "Null"
      variable = "aws:RequestTag/elbv2.k8s.aws/cluster"
      values   = ["false"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["elasticloadbalancing:RegisterTargets", "elasticloadbalancing:DeregisterTargets"]
    resources = ["arn:aws:elasticloadbalancing:*:*:targetgroup/*/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:ModifyRule",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "alb_controller" {
  count = var.ingress_enabled ? 1 : 0

  name   = "${var.cluster_name}-${var.region}-alb-controller-policy"
  policy = data.aws_iam_policy_document.alb_controller.json
}

resource "aws_iam_role" "alb_controller" {
  count = var.ingress_enabled ? 1 : 0

  name               = "${var.cluster_name}-${var.region}-alb-controller-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["alb"].json
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  count = var.ingress_enabled ? 1 : 0

  role       = aws_iam_role.alb_controller[0].name
  policy_arn = aws_iam_policy.alb_controller[0].arn
}

# -----------------------------------------------------------------------------
# External DNS (ingress only). Change records in the configured hosted zone;
# list across all zones (the controller enumerates to find the match).
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "external_dns" {
  statement {
    sid       = "ChangeRecords"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${var.route53_zone_id}"]
  }

  statement {
    sid       = "ListZones"
    effect    = "Allow"
    actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "external_dns" {
  count = var.ingress_enabled ? 1 : 0

  name   = "${var.cluster_name}-${var.region}-external-dns-policy"
  policy = data.aws_iam_policy_document.external_dns.json
}

resource "aws_iam_role" "external_dns" {
  count = var.ingress_enabled ? 1 : 0

  name               = "${var.cluster_name}-${var.region}-external-dns-irsa"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["external_dns"].json
}

resource "aws_iam_role_policy_attachment" "external_dns" {
  count = var.ingress_enabled ? 1 : 0

  role       = aws_iam_role.external_dns[0].name
  policy_arn = aws_iam_policy.external_dns[0].arn
}
