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

  # OPTIMIZE_UTILIZATION makes the Cluster Autoscaler more aggressive about
  # bin-packing — when a pending pod could fit on multiple node pools (we
  # have 5 batch pool shapes sharing the same label/taint), it picks the
  # smallest-fitting pool and prefers consolidating onto fewer nodes. This
  # is the GKE-side counterpart of AWS Cluster Autoscaler's "least-waste"
  # expander, and it's what makes the multi-pool batch layout actually save
  # money (vs picking pools at random).
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

# Batch node pools — one resource per shape in local.batch_pool_specs.
#
# All pools share the same Kubernetes label (role=batch) and taint
# (dedicated=batch:NoSchedule), so the scheduler treats them as a single
# logical pool. The GKE Cluster Autoscaler picks the smallest-fitting pool
# when a pending pod arrives, minimising waste — small jobs land on small
# nodes, big jobs on big nodes. Mirrors AWS CloudFormation's 5-pool batch
# layout (m7i.4xlarge / .8xlarge / .16xlarge + r7i.8xlarge / .16xlarge).
#
# Pool name: "batch-${shape}" e.g. batch-16c-64g. The shape is also exposed
# as a label (platforma.bio/batch-pool=<shape>) for diagnostics — workloads
# don't select on it, the autoscaler picks based on resource requests.
resource "google_container_node_pool" "batch" {
  for_each = local.batch_pool_specs

  name     = "batch-${each.key}"
  project  = var.project_id
  location = local.zone
  cluster  = google_container_cluster.primary.name

  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = local.effective_batch_pool_max_nodes[each.key]
  }

  node_config {
    machine_type = each.value.machine_type
    disk_type    = "pd-balanced"
    disk_size_gb = var.batch_pool_disk_size_gb

    labels = {
      role                       = "batch"
      dedicated                  = "batch"
      "platforma.bio/batch-pool" = each.key
    }

    taint {
      key    = "dedicated"
      value  = "batch"
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
