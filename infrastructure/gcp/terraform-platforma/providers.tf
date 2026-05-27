# =============================================================================
# Provider configuration — k8s/helm/kubectl host sourced via data sources
# =============================================================================
# This module is applied AFTER the infra module finishes (orchestrated by
# cloudshell/install.sh). By the time we plan here, the GKE cluster already
# exists in GCP, so data.google_container_cluster reads concrete attributes
# at plan time. That avoids the chicken-and-egg where providers referencing a
# managed resource (`google_container_cluster.primary`) saw unknown values at
# plan time — which kubectl provider v2.4+ rejects with a confusing
# "no configuration has been provided" error.
#
# Decoupling the provider config from a managed resource also means the apps
# module can be applied/destroyed independently of the cluster module, which
# is essential for upgrade-only flows (bump Platforma chart version without
# touching the cluster).
# =============================================================================

provider "google" {
  project = var.project_id
  region  = var.region

  user_project_override = true
  billing_project       = var.project_id
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  user_project_override = true
  billing_project       = var.project_id
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.primary.endpoint}"
  cluster_ca_certificate = base64decode(data.google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.primary.endpoint}"
    cluster_ca_certificate = base64decode(data.google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}

provider "kubectl" {
  host                   = "https://${data.google_container_cluster.primary.endpoint}"
  cluster_ca_certificate = base64decode(data.google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
  load_config_file       = false
}
