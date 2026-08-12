terraform {
  # 1.5 is the minimum: Infrastructure Manager runs Terraform 1.5.7 in its
  # managed runner. Using a higher floor would block the IM path.
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "6.50.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "6.50.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.9.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "3.2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.38.0"
    }
    # Pinned below 2.4: alekc/kubectl 2.4.0 introduced eager plan-time
    # provider-config validation that rejects this module's provider pattern
    # (host = google_container_cluster.primary.endpoint — an unknown value at
    # plan time on a fresh apply). This monolithic module intentionally keeps
    # the managed-resource provider wiring, so it must stay on 2.1–2.3. The
    # split infra/platforma modules solve this differently (data-source host)
    # and are free to use ~> 2.4. Do NOT widen this ceiling here.
    kubectl = {
      source  = "alekc/kubectl"
      version = "2.3.1"
    }
    http = {
      source  = "hashicorp/http"
      version = "3.6.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "3.3.0"
    }
  }

  # No backend block here — Infrastructure Manager manages state externally.
  # For local development, backend.tf provides a GCS backend (gitignored when
  # packaging for IM; see infrastructure/gcp/README.md for the local dev flow).
}
