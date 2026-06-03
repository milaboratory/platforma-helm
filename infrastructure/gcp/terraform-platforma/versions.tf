terraform {
  # 1.5 is the minimum: Infrastructure Manager runs Terraform 1.5.7 in its
  # managed runner. Using a higher floor would block the IM path.
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    # kubectl 2.4.0 introduced eager plan-time provider config validation
    # that breaks the old monolithic module's "host = ${managed-resource}.endpoint"
    # pattern. The new platforma module routes through data.google_container_
    # cluster instead — by the time we plan here, the infra module has
    # already created the cluster, so the data source returns concrete
    # values and the eager validation passes. Bumping to ~> 2.4 is therefore
    # safe in this module shape (and intentionally rejected for the old
    # monolithic terraform/ module).
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.4"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
    # Used by the master-secret BYO lookup in app.tf — shells out to
    # `gcloud secrets versions access` so an existing Secret Manager
    # entry overrides the random_password fallback.
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

  # No backend block here — Infrastructure Manager manages state externally.
}
