# =============================================================================
# Service accounts + Workload Identity bindings
# =============================================================================
# Two GCP service accounts are created, mirroring the chart's K8s SA split:
#   platforma-server — Platforma pod; reads secrets, writes to primary GCS bucket
#   platforma-jobs   — job pods; writes results to primary GCS bucket
#
# Each GCP SA is bound via Workload Identity to the corresponding K8s SA created
# by the Helm chart. The chart's K8s SA names default to:
#   <release>-platforma       (server)
#   <release>-platforma-jobs  (jobs)
# With release name "platforma" this yields platforma-platforma /
# platforma-platforma-jobs. The chart annotates the K8s SA with the GCP SA
# email (see values-gcp-gcs.yaml).
# =============================================================================

locals {
  k8s_namespace = var.platforma_namespace
  # The chart's `platforma.fullname` helper: if release name contains chart name ("platforma"),
  # use release name directly. With release="platforma", server SA = "platforma".
  k8s_sa_server = var.helm_release_name
  k8s_sa_jobs   = "${var.helm_release_name}-jobs"
}

resource "google_service_account" "server" {
  account_id   = "platforma-server"
  display_name = "Platforma server (Workload Identity for K8s SA ${local.k8s_sa_server})"
  project      = var.project_id

  depends_on = [google_project_service.enabled]
}

resource "google_service_account" "jobs" {
  account_id   = "platforma-jobs"
  display_name = "Platforma jobs (Workload Identity for K8s SA ${local.k8s_sa_jobs})"
  project      = var.project_id

  depends_on = [google_project_service.enabled]
}

# Primary GCS bucket access — server reads/writes project state + results.
resource "google_storage_bucket_iam_member" "server_bucket_admin" {
  bucket = google_storage_bucket.primary.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.server.email}"
}

# Primary GCS bucket access — jobs write results.
resource "google_storage_bucket_iam_member" "jobs_bucket_admin" {
  bucket = google_storage_bucket.primary.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.jobs.email}"
}

# Auto-grant the runtime SAs read access to same-project GCS data library
# buckets. The user lists buckets in var.data_libraries; for any GCS entry
# whose project_id is empty (defaults to this project) or matches var.project_id,
# we grant roles/storage.objectViewer to both runtime SAs (server reads /
# imports; jobs may also need to read raw inputs in some workflows).
#
# Cross-project entries (project_id set to a different project) are skipped —
# the deployer SA can't touch IAM on a foreign project without extra setup, so
# the user must pre-grant manually. S3 entries are skipped (auth via HMAC keys).
#
# Without this, fresh installs of same-project data libraries silently fail
# at pod-init time with "AccessDenied" listing the bucket — discovered only
# when the pod can't initialise its data sources.
locals {
  same_project_gcs_libraries = {
    for lib in var.data_libraries : lib.name => lib
    if lib.type == "gcs" && (lib.project_id == "" || lib.project_id == var.project_id)
  }
}

resource "google_storage_bucket_iam_member" "data_library_server_objectviewer" {
  for_each = local.same_project_gcs_libraries

  bucket = each.value.bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.server.email}"
}

resource "google_storage_bucket_iam_member" "data_library_jobs_objectviewer" {
  for_each = local.same_project_gcs_libraries

  bucket = each.value.bucket
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.jobs.email}"
}

# Workload Identity: bind GCP SA -> K8s SA.
# This grants the K8s SA permission to impersonate the GCP SA.
resource "google_service_account_iam_member" "server_wi" {
  service_account_id = google_service_account.server.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.k8s_namespace}/${local.k8s_sa_server}]"
}

resource "google_service_account_iam_member" "jobs_wi" {
  service_account_id = google_service_account.jobs.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${local.k8s_namespace}/${local.k8s_sa_jobs}]"
}

# Self-impersonation for signBlob: Platforma server presigns GCS URLs for the
# Desktop App to download results. Signing blobs requires `iam.serviceAccounts.signBlob`,
# which Workload Identity does NOT grant by default. Granting the server SA the
# Token Creator role on itself unlocks self-signing.
resource "google_service_account_iam_member" "server_token_creator_self" {
  service_account_id = google_service_account.server.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.server.email}"
}

resource "google_service_account_iam_member" "jobs_token_creator_self" {
  service_account_id = google_service_account.jobs.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.jobs.email}"
}
