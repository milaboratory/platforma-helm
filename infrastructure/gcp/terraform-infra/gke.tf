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
