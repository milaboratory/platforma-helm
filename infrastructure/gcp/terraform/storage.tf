resource "random_id" "bucket_suffix" {
  byte_length = 4
}

resource "google_storage_bucket" "primary" {
  name          = var.gcs_bucket_name != "" ? var.gcs_bucket_name : "platforma-${var.cluster_name}-${random_id.bucket_suffix.hex}"
  project       = var.project_id
  location      = var.region
  storage_class = "STANDARD"

  uniform_bucket_level_access = true
  # force_destroy = false — primary storage holds user project data. tofu destroy
  # leaves the bucket in place; users must delete it manually if they really want
  # the data gone (matches AWS S3 retention pattern in the CloudFormation runbook).
  force_destroy = false

  versioning {
    enabled = false
  }

  cors {
    origin          = ["*"]
    method          = ["GET", "HEAD", "PUT", "POST", "DELETE"]
    response_header = ["*"]
    max_age_seconds = 3600
  }

  labels = {
    platform = "platforma"
    cluster  = var.cluster_name
  }

  depends_on = [google_project_service.enabled]
}

resource "google_filestore_instance" "workspace" {
  name     = "${var.cluster_name}-workspace"
  project  = var.project_id
  location = local.zone
  tier     = var.filestore_tier

  file_shares {
    capacity_gb = local.effective_workspace_capacity_gb
    name        = var.workspace_share_name

    nfs_export_options {
      ip_ranges   = [google_compute_subnetwork.nodes.ip_cidr_range]
      access_mode = "READ_WRITE"
      squash_mode = "NO_ROOT_SQUASH"
    }
  }

  networks {
    network      = google_compute_network.vpc.name
    modes        = ["MODE_IPV4"]
    connect_mode = contains(["BASIC_HDD", "BASIC_SSD"], var.filestore_tier) ? "DIRECT_PEERING" : "PRIVATE_SERVICE_ACCESS"
  }

  depends_on = [
    google_service_networking_connection.psa,
    google_project_service.enabled,
  ]
}
