# =============================================================================
# Launch templates + managed node groups
# =============================================================================
# Mirrors cloudformation-eks-1-35.yaml node groups: one always-on system pool,
# a scale-from-zero UI pool, five scale-from-zero batch pools, and (optionally)
# six scale-from-zero GPU pools. MaxSize per pool comes from the deployment-size
# preset (presets.tf).
#
# All node groups except system scale from zero (DesiredSize/MinSize = 0); the
# Cluster Autoscaler grows them on demand. desired_size is ignored after create
# so autoscaler-driven scaling doesn't show up as drift.
#
# EKS managed node groups auto-tag their ASGs with k8s.io/cluster-autoscaler/*
# and eks:cluster-name, so autoscaler auto-discovery and the scale IAM condition
# work without extra tagging — except the GPU VRAM node-template label, which CF
# applies to the ASG via a post-create script and we apply with
# aws_autoscaling_group_tag below.
# =============================================================================

# -----------------------------------------------------------------------------
# Launch templates. No image_id — EKS selects the optimised AMI from ami_type on
# the node group. Root volume sized per tier; encrypted gp3 throughout.
# -----------------------------------------------------------------------------
locals {
  node_root_volume_gib = {
    small  = 50  # system + UI
    medium = 100 # batch 16c / 32c
    large  = 200 # batch 64c + high-memory
  }
}

resource "aws_launch_template" "node" {
  for_each = local.node_root_volume_gib

  name_prefix = "${var.cluster_name}-${each.key}-"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = each.value
      volume_type = "gp3"
      encrypted   = "true"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { platforma = var.cluster_name }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { platforma = var.cluster_name }
  }
}

resource "aws_launch_template" "gpu" {
  count = var.enable_gpu ? 1 : 0

  name_prefix = "${var.cluster_name}-gpu-"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 100
      volume_type = "gp3"
      encrypted   = "true"
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { platforma = var.cluster_name }
  }

  tag_specifications {
    resource_type = "volume"
    tags          = { platforma = var.cluster_name }
  }
}

# -----------------------------------------------------------------------------
# System node group. Pinned to a single AZ because Platforma's database/log EBS
# volumes are AZ-bound — spreading system nodes across AZs risks a node landing
# where its PV cannot follow.
# -----------------------------------------------------------------------------
locals {
  system_subnet_id = local.resolved_private_subnet_ids[index(["a", "b", "c"], var.system_node_az)]

  node_attachments = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "system-v4"
  node_role_arn   = aws_iam_role.node.arn
  version         = "1.35"
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = ["m7i.4xlarge"]
  subnet_ids      = [local.system_subnet_id]

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 4
  }

  launch_template {
    id      = aws_launch_template.node["small"].id
    version = aws_launch_template.node["small"].latest_version
  }

  labels = { "node.kubernetes.io/pool" = "system" }

  tags = { "nodegroup-type" = "system" }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

# -----------------------------------------------------------------------------
# UI node group. Scale-from-zero; tainted so only UI-pool workloads land here.
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "ui" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "ui-v2"
  node_role_arn   = aws_iam_role.node.arn
  version         = "1.35"
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = ["t3.xlarge"]
  subnet_ids      = local.resolved_private_subnet_ids

  scaling_config {
    desired_size = 0
    min_size     = 0
    max_size     = local.preset.max_ui
  }

  launch_template {
    id      = aws_launch_template.node["small"].id
    version = aws_launch_template.node["small"].latest_version
  }

  labels = { "node.kubernetes.io/pool" = "ui" }

  taint {
    key    = "dedicated"
    value  = "ui"
    effect = "NO_SCHEDULE"
  }

  tags = { "nodegroup-type" = "ui" }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

# -----------------------------------------------------------------------------
# Batch node groups. Five CPU/memory tiers, all scale-from-zero, tainted to the
# batch pool. MaxSize per tier from the deployment-size preset.
# -----------------------------------------------------------------------------
locals {
  batch_node_groups = {
    "batch-16c-64g-v2" = {
      instance_type   = "m7i.4xlarge"
      launch_template = "medium"
      max_size        = local.preset.max_batch_16c64g
    }
    "batch-32c-128g-v2" = {
      instance_type   = "m7i.8xlarge"
      launch_template = "medium"
      max_size        = local.preset.max_batch_32c128g
    }
    "batch-64c-256g-v2" = {
      instance_type   = "m7i.16xlarge"
      launch_template = "large"
      max_size        = local.preset.max_batch_64c256g
    }
    "batch-32c-256g-v2" = {
      instance_type   = "r7i.8xlarge"
      launch_template = "large"
      max_size        = local.preset.max_batch_32c256g
    }
    "batch-64c-512g-v2" = {
      instance_type   = "r7i.16xlarge"
      launch_template = "large"
      max_size        = local.preset.max_batch_64c512g
    }
  }
}

resource "aws_eks_node_group" "batch" {
  for_each = local.batch_node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  version         = "1.35"
  ami_type        = "AL2023_x86_64_STANDARD"
  instance_types  = [each.value.instance_type]
  subnet_ids      = local.resolved_private_subnet_ids

  scaling_config {
    desired_size = 0
    min_size     = 0
    max_size     = each.value.max_size
  }

  launch_template {
    id      = aws_launch_template.node[each.value.launch_template].id
    version = aws_launch_template.node[each.value.launch_template].latest_version
  }

  labels = { "node.kubernetes.io/pool" = "batch" }

  taint {
    key    = "dedicated"
    value  = "batch"
    effect = "NO_SCHEDULE"
  }

  tags = { "nodegroup-type" = replace(each.key, "-v2", "") }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

# -----------------------------------------------------------------------------
# GPU node groups (optional). Six VRAM tiers, scale-from-zero, no cost when idle.
# gpu-3g/6g/12g are fractional L4 (g6f), gpu-24g a full L4 (g6), gpu-48g/96g
# L40S (g6e); the "96g" tier is 4× L40S
# "96g" doesn't provide bigger GPU only bigger RAM and CPU.
#
# Two taints: nvidia.com/gpu keeps non-GPU pods off; nvidia.com/gpu-not-ready is
# removed by the NVIDIA device plugin once drivers are up, preventing pods from
# landing before the GPU is usable.
# -----------------------------------------------------------------------------
locals {
  gpu_node_groups = {
    "gpu-3g"  = { instance_type = "g6f.xlarge", gpu_memory_gib = "3" }
    "gpu-6g"  = { instance_type = "g6f.2xlarge", gpu_memory_gib = "6" }
    "gpu-12g" = { instance_type = "g6f.4xlarge", gpu_memory_gib = "12" }
    "gpu-24g" = { instance_type = "g6.2xlarge", gpu_memory_gib = "24" }
    "gpu-48g" = { instance_type = "g6e.2xlarge", gpu_memory_gib = "48" }
    "gpu-96g" = { instance_type = "g6e.12xlarge", gpu_memory_gib = "48" }
  }

  gpu_max_size = {
    "gpu-3g"  = local.preset.max_gpu_3g
    "gpu-6g"  = local.preset.max_gpu_6g
    "gpu-12g" = local.preset.max_gpu_12g
    "gpu-24g" = local.preset.max_gpu_24g
    "gpu-48g" = local.preset.max_gpu_48g
    "gpu-96g" = local.preset.max_gpu_96g
  }

  active_gpu_node_groups = var.enable_gpu ? local.gpu_node_groups : {}
}

resource "aws_eks_node_group" "gpu" {
  for_each = local.active_gpu_node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.key
  node_role_arn   = aws_iam_role.node.arn
  version         = "1.35"
  ami_type        = "AL2023_x86_64_NVIDIA"
  capacity_type   = "ON_DEMAND"
  instance_types  = [each.value.instance_type]
  subnet_ids      = local.resolved_private_subnet_ids

  scaling_config {
    desired_size = 0
    min_size     = 0
    max_size     = local.gpu_max_size[each.key]
  }

  launch_template {
    id      = aws_launch_template.gpu[0].id
    version = aws_launch_template.gpu[0].latest_version
  }

  labels = { "platforma.bio/gpu-memory-gib" = each.value.gpu_memory_gib }

  taint {
    key    = "nvidia.com/gpu"
    value  = "present"
    effect = "NO_SCHEDULE"
  }

  taint {
    key    = "nvidia.com/gpu-not-ready"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  tags = { "nodegroup-type" = each.key }

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker,
    aws_iam_role_policy_attachment.node_cni,
    aws_iam_role_policy_attachment.node_ecr_readonly,
  ]
}

# The Cluster Autoscaler can only scale a GPU pool from zero if it knows the
# node's shape before any node exists. EKS does not propagate node-group labels,
# taints, or extended resources to the ASG, so publish them as node-template
# tags (CF does this in a post-create script; here it's declarative). All three
# are required for correct scale-from-zero of pending GPU pods:
#   * label/...gpu-memory-gib   — the VRAM label pods select on
#   * resources/nvidia.com/gpu  — tells CA the node will expose 1 GPU
#   * taint/nvidia.com/gpu      — tells CA the node is tainted, so it only
#                                 scales this pool for pods that tolerate it
locals {
  gpu_asg_node_template_tags = merge([
    for ng_key, ng in local.active_gpu_node_groups : {
      "${ng_key}|gpu-memory-gib" = {
        ng_key = ng_key
        key    = "k8s.io/cluster-autoscaler/node-template/label/platforma.bio/gpu-memory-gib"
        value  = ng.gpu_memory_gib
      }
      "${ng_key}|gpu-resource" = {
        ng_key = ng_key
        key    = "k8s.io/cluster-autoscaler/node-template/resources/nvidia.com/gpu"
        value  = "1"
      }
      "${ng_key}|gpu-taint" = {
        ng_key = ng_key
        key    = "k8s.io/cluster-autoscaler/node-template/taint/nvidia.com/gpu"
        value  = "present:NoSchedule"
      }
    }
  ]...)
}

resource "aws_autoscaling_group_tag" "gpu_node_template" {
  for_each = local.gpu_asg_node_template_tags

  autoscaling_group_name = aws_eks_node_group.gpu[each.value.ng_key].resources[0].autoscaling_groups[0].name

  tag {
    key                 = each.value.key
    value               = each.value.value
    propagate_at_launch = true
  }
}
