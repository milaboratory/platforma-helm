# =============================================================================
# Local-development Terraform state backend
# =============================================================================
# Used when running `tofu`/`terraform` from a developer machine. The state
# bucket must exist before `tofu init` — create it once with:
#
#   gcloud storage buckets create gs://YOUR-tfstate-bucket \
#     --project=YOUR-PROJECT --location=europe-west1 \
#     --uniform-bucket-level-access
#   gcloud storage buckets update gs://YOUR-tfstate-bucket --versioning
#
# Override the bucket/prefix for your own project via:
#   tofu init -backend-config="bucket=YOUR-tfstate" -backend-config="prefix=YOUR-prefix"
#
# This file is EXCLUDED from the Infrastructure Manager source bundle (CI
# packaging in Phase 4 strips it); IM manages state internally and rejects
# bundles that include their own backend block.
# =============================================================================

terraform {
  backend "gcs" {
    bucket = "YOUR-tfstate-bucket"
    prefix = "infrastructure/gcp/infra"
  }
}
