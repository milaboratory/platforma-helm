provider "google" {
  project = var.project_id
  region  = var.region

  # Required for cloudquotas.googleapis.com (and other "user project required"
  # APIs) when authenticating via Application Default Credentials. Sets the
  # X-Goog-User-Project header so the API knows which project to bill the
  # request to. IM service accounts have this implicit; local ADC does not.
  user_project_override = true
  billing_project       = var.project_id
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  user_project_override = true
  billing_project       = var.project_id
}

data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  token                  = data.google_client_config.default.access_token
}

provider "helm" {
  kubernetes = {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
    token                  = data.google_client_config.default.access_token
  }
}

provider "kubectl" {
  # Terraform configures a provider whenever its resource/data BLOCKS exist in
  # config, even when count/for_each expand to zero instances. So gating the
  # AppWrapper objects on var.enable_appwrapper is not enough on its own: this
  # provider is still configured, and unlike the kubernetes/helm providers,
  # alekc/kubectl does not defer on an unknown host — on a first from-scratch
  # apply (cluster not created yet, endpoint unknown) it fails the plan with
  # "no configuration has been provided".
  #
  # When AppWrapper is disabled (the revision-1 cluster-bootstrap pass), feed
  # the provider a known dummy host so configuration succeeds. It is never used
  # to reach a cluster because kubectl_manifest.appwrapper has no instances.
  # When enabled (revision 2), the cluster already exists in state, so the real
  # endpoint is known at plan time.
  host                   = var.enable_appwrapper ? "https://${google_container_cluster.primary.endpoint}" : "https://127.0.0.1"
  cluster_ca_certificate = var.enable_appwrapper ? base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate) : ""
  token                  = data.google_client_config.default.access_token
  load_config_file       = false
}
