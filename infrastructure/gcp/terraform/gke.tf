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

  depends_on = [google_project_service.enabled]
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
    max_node_count = var.ui_pool_max_nodes
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

resource "google_container_node_pool" "batch" {
  name     = "batch"
  project  = var.project_id
  location = local.zone
  cluster  = google_container_cluster.primary.name

  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = var.batch_pool_max_nodes
  }

  node_config {
    machine_type = var.batch_pool_machine_type
    disk_type    = "pd-balanced"
    disk_size_gb = var.batch_pool_disk_size_gb

    labels = {
      role      = "batch"
      dedicated = "batch"
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
