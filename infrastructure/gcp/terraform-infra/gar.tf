# =============================================================================
# Container image pull-through cache (quay.io mirror)
# =============================================================================
# Platforma block software images default to the prefix
# containers.pl-open.science/milaboratories/pl-containers, served from
# quay.io/milaboratories/pl-containers. This GAR remote repository proxies
# quay.io so the cluster pulls large images (e.g. the ~8GB python-rapids
# runenv) from a same-region cache instead of over the public internet on
# every job. The platforma module points the backend at it via
# --default-docker-registry (terraform-platforma/app.tf).
#
# GCP equivalent of the AWS ECR pull-through cache (aws/terraform/infra/storage.tf).
# GAR is fully managed: there is no proxy to deploy or operate, unlike a
# self-hosted Distribution/zot registry.
#
# The repo id is namespaced with resource_name_prefix so multiple Platforma
# deployments can share one project without colliding (same rationale as the
# service accounts and VPC).
# =============================================================================

resource "google_artifact_registry_repository" "pl_containers" {
  project       = var.project_id
  location      = var.region
  repository_id = "${var.resource_name_prefix}-containers"
  description   = "Pull-through cache mirror of quay.io for Platforma block software images"
  format        = "DOCKER"
  mode          = "REMOTE_REPOSITORY"

  remote_repository_config {
    description = "quay.io"
    docker_repository {
      custom_repository {
        uri = "https://quay.io"
      }
    }
  }

  cleanup_policies {
    id     = "expire-cached-after-90-days"
    action = "DELETE"
    condition {
      older_than = "7776000s" # 90 days, matches the AWS ECR cache lifecycle
    }
  }

  depends_on = [google_project_service.enabled]
}

# Runtime SAs read from the cache. On the GKE/Kueue path kubelet pulls using the
# node pool's default compute SA, which already has same-project Artifact Registry
# read; these grants cover the Google Batch path, where job VMs run-as the server
# SA and docker-login to GAR with an SA token (--google-artifact-registry in the
# platforma module). Granting both runtime SAs keeps it correct for either runner.
resource "google_artifact_registry_repository_iam_member" "pl_containers_server_reader" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.pl_containers.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.server.email}"
}

resource "google_artifact_registry_repository_iam_member" "pl_containers_jobs_reader" {
  project    = var.project_id
  location   = var.region
  repository = google_artifact_registry_repository.pl_containers.name
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${google_service_account.jobs.email}"
}
