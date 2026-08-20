resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  project  = var.project_id
  location = local.zone

  network    = google_compute_network.vpc.id
  subnetwork = google_compute_subnetwork.nodes.id

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  gateway_api_config {
    channel = "CHANNEL_STANDARD"
  }

  addons_config {
    gcp_filestore_csi_driver_config {
      enabled = true
    }
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  datapath_provider = "ADVANCED_DATAPATH"

  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false

  # Cluster-wide Node Auto-Provisioning is intentionally OFF.
  #
  # We tried cluster-wide NAP for the batch tier and hit a hard wall: without
  # a pinned machine family, GKE Standard NAP shapes nodes within the default
  # E2 family, which is ratio-capped (~4-6.5 GiB/vCPU). Batch jobs request a
  # high memory:CPU ratio (e.g. 62 vCPU / 484 GiB ≈ 7.8 GiB/vCPU), which no
  # E2 shape can satisfy, and NAP does NOT reach for predefined highmem
  # machine types on its own. Result: every batch ProvisioningRequest failed
  # with `no.scale.up.nap.pod.zonal.resources.exceeded` ("no machine type
  # could fit the request"). Cluster-wide NAP also created stray e2 pools for
  # floating kube-system pods during bootstrap.
  #
  # Instead, batch capacity is provisioned by a custom ComputeClass
  # (terraform-platforma/computeclass.tf) that names n2d-highmem / n2-highmem
  # machine types explicitly and auto-creates pools standalone (GKE >= 1.33.3
  # supports nodePoolAutoCreation without cluster-wide NAP). Only pods that
  # select the compute class trigger pool creation — system/ui/kube-system
  # stay on their static pools.
  #
  # OPTIMIZE_UTILIZATION still tunes the autoscaler's bin-packing for the
  # static pools and the ComputeClass-created pools (least-waste expander).
  cluster_autoscaling {
    autoscaling_profile = "OPTIMIZE_UTILIZATION"
  }

  # Private nodes (no external IPs); public control plane endpoint kept so
  # kubectl from anywhere works without a bastion / IAP tunnel.
  #
  # Gated on var.enable_private_nodes (default true) so existing public-nodes
  # deployments can upgrade without forcing cluster recreation. Flipping the
  # flag is a destroy+recreate operation; new deployments get private-by-
  # default.
  #
  # Why private nodes:
  #   - Each public-IP node consumes 1 IN_USE_ADDRESSES quota slot. With 30+
  #     possible nodes (5 batch pools + UI + system), the default 8-IP regional
  #     quota was a constant blocker on first installs.
  #   - Better security posture: nodes not directly reachable from the
  #     internet, only through the cluster's load balancers.
  #
  # Egress is via Cloud NAT in network.tf (also gated on this variable).
  # Google APIs (Storage, IAM, Logging, Monitoring) go through Private Google
  # Access on the nodes subnet — faster and avoids NAT processing fees on the
  # high-volume GCS traffic.
  #
  # master_ipv4_cidr_block is the /28 range used for the master's PRIVATE
  # endpoint. Even with public endpoint enabled (enable_private_endpoint = false),
  # GCP requires this CIDR to be reserved. Configurable via var.master_ipv4_cidr_block
  # if it conflicts with existing peerings.
  dynamic "private_cluster_config" {
    for_each = var.enable_private_nodes ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = false # public control plane — kubectl from anywhere
      master_ipv4_cidr_block  = var.master_ipv4_cidr_block
    }
  }

  depends_on = [
    google_project_service.enabled,
    # NAT must exist before the cluster comes up — otherwise the first node
    # pulls (system pods) hang trying to reach the internet from internal IPs.
    # Resource has count = enable_private_nodes ? 1 : 0; depends_on accepts
    # the whole resource address and resolves the empty case as a no-op.
    google_compute_router_nat.primary,
  ]
}

resource "google_container_node_pool" "system" {
  name     = "system"
  project  = var.project_id
  location = local.zone
  cluster  = google_container_cluster.primary.name

  initial_node_count = var.system_pool_node_count

  node_config {
    machine_type = var.system_pool_machine_type
    disk_type    = "pd-balanced"
    disk_size_gb = 100

    labels = {
      role = "system"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Platforma backend node pool — dedicated to the Platforma server pod so its
# memory can grow into a whole node without contending with the cluster-support
# services on the system pool (MILAB-6566). Fixed single node (the backend is a
# single-instance pod). Tainted dedicated=platforma:NoSchedule so nothing else
# schedules here; the chart tolerates the taint and selects role=platforma via
# app.nodeSelector (terraform-platforma/app.tf). Same zone as the system pool
# (local.zone), so the zonal database PD and Filestore attach without issue.
resource "google_container_node_pool" "platforma" {
  name     = "platforma"
  project  = var.project_id
  location = local.zone
  cluster  = google_container_cluster.primary.name

  initial_node_count = var.platforma_pool_node_count

  node_config {
    machine_type = var.platforma_pool_machine_type
    disk_type    = "pd-balanced"
    disk_size_gb = 100

    labels = {
      role = "platforma"
    }

    taint {
      key    = "dedicated"
      value  = "platforma"
      effect = "NO_SCHEDULE"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "google_container_node_pool" "ui" {
  name     = "ui"
  project  = var.project_id
  location = local.zone
  cluster  = google_container_cluster.primary.name

  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = local.effective_ui_pool_max_nodes
  }

  node_config {
    machine_type = var.ui_pool_machine_type
    disk_type    = "pd-balanced"
    disk_size_gb = 100

    labels = {
      role      = "ui"
      dedicated = "ui"
    }

    taint {
      key    = "dedicated"
      value  = "ui"
      effect = "NO_SCHEDULE"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# Batch node pools — created on demand by the platforma-batch ComputeClass
# (terraform-platforma/computeclass.tf), NOT by cluster-wide NAP (which is off
# — see cluster_autoscaling block above). No explicit google_container_node_pool
# resources here; the ComputeClass's nodePoolAutoCreation provisions pools from
# its machine-type priority list, with the dedicated=batch:NoSchedule taint and
# role=batch label from its nodePoolConfig.

# =============================================================================
# L4 GPU node pools — one static pool per machine shape
# =============================================================================
# Gated on local.gpu_l4_enabled (var.enable_gpu AND L4 has usable zones). When
# off, no resources are created and the cluster runs identically to a pre-GPU
# deployment. See presets.tf for the per-SKU enable/locations resolution.
#
# Why static pools instead of a ComputeClass:
#   GKE's Cluster Autoscaler only triggers ComputeClass scale-up when a pod
#   carries an explicit cloud.google.com/compute-class nodeSelector. Pure
#   nodeAffinity on the ComputeClass's nodeLabels does NOT match (validated
#   empirically on psv-gpu2-cluster 2026-06-08, also confirmed in the public
#   docs at https://docs.cloud.google.com/kubernetes-engine/docs/concepts/about-custom-compute-classes).
#
#   Static pools follow the long-standing kubernetes/autoscaler convention:
#   the CA reads each pool's template node (machine_type, labels, taints,
#   accelerators) before any node is created and pre-matches pending pods
#   to the template. A pod with nodeAffinity on platforma.bio/gpu-memory-gib
#   thus reaches the right pool without any pool name in the pod spec.
#   Identical mechanism to AWS Cluster Autoscaler's
#   `k8s.io/cluster-autoscaler/node-template/label/*` ASG tags
#   (helm/infrastructure/aws/cloudformation/cloudformation-eks-1-35.yaml:2018-2213).
#
# Why one pool per machine shape (5 pools instead of 1):
#   Each shape has a distinct CPU and RAM ceiling. The CA picks the smallest
#   shape whose template fits the pending pod (OPTIMIZE_UTILIZATION expander,
#   set on the cluster above). For a small job (e.g. 4 vCPU / 8 GiB / 1 GPU)
#   that's g2-standard-4; for a large job (32 vCPU / 100 GiB / 1 GPU) that's
#   g2-standard-32. Bin-packing then co-tenants additional GPU pods on the
#   same node when possible.
#
# Each pool: 1× NVIDIA L4, label platforma.bio/gpu-memory-gib=24 (the SKU
# contract with the job template's nodeAffinity), label role=gpu, taint
# nvidia.com/gpu=present:NoSchedule (pods get the toleration from the chart's
# kueue.pools.gpu.tolerations). Drivers auto-install via
# gpu_driver_installation_config = DEFAULT (GKE >= 1.32.2 auto-installs the
# default NVIDIA driver on accelerator nodes; the cluster's REGULAR channel
# runs >= 1.33 today).
#
# autoscaling 0..N: scale-to-zero when no GPU jobs are pending. N comes from
# the deployment_size preset (presets.tf: gpu_l4_max_nodes_per_shape).
locals {
  # Per-shape L4 pools: map of machine shape (g2-standard-*) -> zones offering
  # it. Comes from install.sh's gcptest.sh discovery (var.gpu_l4_pools), or the
  # full default ladder in [local.zone] for bare terraform — see
  # effective_gpu_l4_pools in presets.tf. Adaptive: a shape the region doesn't
  # offer is simply absent, so no pool is created for it. Empty when L4 disabled.
  gpu_l4_pools = local.gpu_l4_enabled ? local.effective_gpu_l4_pools : {}

  # RTX PRO 6000 single-GPU shapes, same per-shape map. Multi-GPU G4 shapes
  # (g4-standard-96, 192, 384) are deliberately excluded from the ladder (in
  # gcptest.sh / presets.tf) — strict 1-GPU-per-node semantics across the
  # platforma.bio/gpu-memory-gib tier; CA picks shape by host CPU/RAM fit.
  gpu_rtx_pro_6000_pools = local.gpu_rtx_pro_6000_enabled ? local.effective_gpu_rtx_pro_6000_pools : {}
}

resource "google_container_node_pool" "gpu_l4" {
  for_each = local.gpu_l4_pools

  name     = "gpu-l4-${replace(each.key, "g2-standard-", "")}"
  project  = var.project_id
  location = local.zone
  cluster  = google_container_cluster.primary.name
  # Spread this shape's pool across the zones in var.region that offer it
  # (each.value, discovered per shape by gcptest.sh). Cluster Autoscaler picks
  # the zone with available capacity at scale-up — single-zone stockouts no
  # longer block scheduling, and the pool is never placed in a zone lacking
  # this shape.
  node_locations = each.value

  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = local.effective_gpu_l4_max_nodes_per_shape
  }

  node_config {
    machine_type = each.key
    disk_type    = "pd-balanced"
    disk_size_gb = 100

    guest_accelerator {
      type  = "nvidia-l4"
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    labels = {
      role                           = "gpu"
      "platforma.bio/gpu-memory-gib" = "24"
    }

    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

# =============================================================================
# RTX PRO 6000 (Blackwell) GPU node pools — one static pool per machine shape
# =============================================================================
# Gated on local.gpu_rtx_pro_6000_enabled (independent of L4 — a region may
# carry one SKU but not the other). Identical mechanism:
# pre-creation template-label matching against pending pod nodeAffinity. Pods
# requesting platforma.bio/gpu-memory-gib > 24 (anything that doesn't fit on
# an L4) land here; the L4's preferred-Lt clause and CA's least-waste expander
# keep small-VRAM jobs on L4.
#
# Each pool: 1× nvidia-rtx-pro-6000, labels role=gpu +
# platforma.bio/gpu-memory-gib=96, taint nvidia.com/gpu=present:NoSchedule,
# autoscaling 0..effective_gpu_rtx_pro_6000_max_nodes_per_shape (presets.tf).
#
# Driver install via gpu_driver_installation_config = DEFAULT (same as L4 —
# GKE 1.32.2+ auto-installs on accelerator nodes).
resource "google_container_node_pool" "gpu_rtx_pro_6000" {
  for_each = local.gpu_rtx_pro_6000_pools

  name     = "gpu-rtx-6000-${replace(each.key, "g4-standard-", "")}"
  project  = var.project_id
  location = local.zone
  cluster  = google_container_cluster.primary.name
  # Spread this shape's pool across the zones in var.region that offer it
  # (each.value, discovered per shape by gcptest.sh) — never placed in a zone
  # lacking this shape.
  node_locations = each.value

  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = local.effective_gpu_rtx_pro_6000_max_nodes_per_shape
  }

  node_config {
    machine_type = each.key
    # G4 machines only support Hyperdisk-Balanced / Hyperdisk-Extreme boot
    # disks (not pd-balanced like G2/L4). Per GCP docs:
    # https://cloud.google.com/compute/docs/disks#hyperdisk-supported-machines
    disk_type    = "hyperdisk-balanced"
    disk_size_gb = 100

    guest_accelerator {
      type  = "nvidia-rtx-pro-6000"
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    labels = {
      role                           = "gpu"
      "platforma.bio/gpu-memory-gib" = "96"
    }

    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
