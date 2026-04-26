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
      version = "~> 3.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # No backend block here — Infrastructure Manager manages state externally.
  # For local development, backend.tf provides a GCS backend (gitignored when
  # packaging for IM; see infrastructure/gcp/README.md for the local dev flow).
}
