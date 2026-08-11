# =============================================================================
# Seed bundle — an intentionally empty Terraform root module
# =============================================================================
# Infrastructure Manager's `import-statefile` requires a deployment that
# already EXISTS and is LOCKED. But the only way to create a deployment is to
# apply a bundle — and applying the real infra/platforma bundle against an
# empty state would provision a second copy of everything.
#
# This bundle breaks that chicken-and-egg: it declares zero resources, so IM
# creates the deployment in seconds with an empty state. We then overwrite
# that empty state with the split state exported from the monolith, and only
# afterwards apply the real bundle on top — which sees every resource already
# under management and plans no creates.
#
# Deliberately has NO required_providers block: with no resources there is
# nothing to configure, and an empty provider set keeps the seed apply fast
# and immune to provider-version drift.
#
# Do not add resources here. If you need to change something about the target
# deployment, change the real bundle and apply it in the step after the
# statefile import.
# =============================================================================

terraform {
  # Matches the floor in terraform-infra/versions.tf and
  # terraform-platforma/versions.tf. IM's managed runner is on 1.5.7.
  required_version = ">= 1.5"
}
