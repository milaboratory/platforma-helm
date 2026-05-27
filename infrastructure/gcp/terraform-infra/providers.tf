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
