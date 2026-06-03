# =============================================================================
# Data sources — read infra-module-managed resources by name/location
# =============================================================================
# All cross-module references are resolved at plan time via data sources, not
# Terraform state remote-state lookups. The platforma module is self-contained:
# given (project_id, cluster_name, zone, helm_release_name, ...) it discovers
# the cluster endpoint, runtime SA emails, Filestore details, GCS bucket, and
# certmap. install.sh passes these identifiers to both modules from a single
# user-supplied tfvars file.
# =============================================================================

# -- Token for the K8s/helm/kubectl providers (above).
data "google_client_config" "default" {}

# -- Cluster endpoint + CA for the providers above. Reads at plan time;
#    the cluster must already exist (apply infra module first).
data "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = local.zone
  project  = var.project_id
}

# -- Runtime service accounts created by the infra module. Read here so we
#    can annotate the K8s SAs the chart creates without depending on infra
#    state directly.
data "google_service_account" "server" {
  account_id = "platforma-server"
  project    = var.project_id
}

data "google_service_account" "jobs" {
  account_id = "platforma-jobs"
  project    = var.project_id
}

# -- Primary GCS bucket — Platforma stores main artefacts here.
#    Bucket name is either the user override or the platforma-${cluster}-${hex}
#    auto-name. Discovery via data source rather than reconstructing the name
#    keeps the apps module robust to the random suffix.
data "google_storage_bucket" "primary" {
  name = var.gcs_bucket
}

# -- Workspace Filestore — chart mounts this as ReadWriteMany for workspace
#    scratch storage.
data "google_filestore_instance" "workspace" {
  name     = var.filestore_instance_name
  location = local.zone
  project  = var.project_id
}

# -- Ingress static IP + certmap names (only when ingress_enabled = true)
#    are computed from var.cluster_name to match what the infra module created
#    (see infra/dns_tls.tf). They're strings consumed by the Gateway YAML; no
#    data source needed — the Gateway controller resolves them at runtime.
#    Centralised in locals so a future rename only happens in one place.
locals {
  ingress_ip_name = "${var.cluster_name}-ingress"
  certmap_name    = "${var.cluster_name}-cert-map"
}
