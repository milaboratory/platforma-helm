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
  # bin-packing — it prefers consolidating pods onto fewer nodes and scales
  # down idle nodes sooner. This applies to the pools the platforma-batch
  # ComputeClass auto-creates (computeclass.tf) as well as the static system/UI
  # pools. It's the GKE-side counterpart of AWS Cluster Autoscaler's
  # "least-waste" expander, and it's what keeps the on-demand batch layout from
  # leaving half-empty nodes running. NOTE: this only tunes the autoscaler; it
  # does NOT enable cluster-wide Node Auto-Provisioning (no resource_limits /
  # auto_provisioning_defaults here). Batch pool creation is driven by the
  # ComputeClass's own nodePoolAutoCreation.
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
  #     possible nodes (ComputeClass-provisioned batch + UI + system), the
  #     default 8-IP regional quota was a constant blocker on first installs.
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

# Batch node pools are NOT static here — they are provisioned on demand by the
# platforma-batch ComputeClass (see computeclass.tf), which spreads batch nodes
# across multiple instance families (n2d → n2 → standard) for capacity-stockout
# fallback. The former static google_container_node_pool.batch (one per shape)
# was removed; system and ui pools above stay static.
