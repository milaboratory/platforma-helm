# =============================================================================
# Provider configuration — infra module
# =============================================================================

provider "aws" {
  region = var.region

  # Tag everything this module creates so customers can find/account for
  # Platforma resources in shared accounts. Merged with any per-resource tags.
  default_tags {
    tags = {
      "platforma.bio/cluster" = var.cluster_name
      "ManagedBy"             = "terraform"
    }
  }
}
