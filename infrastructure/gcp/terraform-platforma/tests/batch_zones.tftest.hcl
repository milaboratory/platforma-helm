# Proves batch_zones reaches the batch ComputeClass only when set, is
# rejected outside var.region, and that kueue_provisioning_request_enabled
# reaches the chart's kueue.provisioningRequest.enabled.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "http" {}
mock_provider "random" {}

variables {
  project_id              = "test-project"
  master_secret_secret_id = "test-master-secret"
  gcs_bucket              = "test-bucket"
  filestore_instance_name = "test-filestore"
  license_key             = "test-license"
  region                  = "us-central1"
  # sha256 of the mocked install.yaml below
  appwrapper_install_yaml_sha256 = "75eb65728a461afea46ec0f45453fe865b76597f0967b64e4bb328753b497d29"
}

override_data {
  target = data.http.appwrapper_manifest
  values = {
    # Holds the upstream resources block once, so helm.tf's integrity
    # postconditions pass without the real release download.
    response_body = "image: quay.io/ibm/appwrapper:v1.2.0\n        resources:\n          limits:\n            cpu: \"2\"\n            memory: 128Mi\n          requests:\n            cpu: 100m\n            memory: 64Mi\n"
  }
}

override_data {
  target = data.kubectl_file_documents.appwrapper
  values = {
    documents = []
    manifests = {
      "/api/v1/namespaces/appwrapper-system" = "apiVersion: v1\nkind: Namespace\nmetadata:\n  name: appwrapper-system\n"
    }
  }
}

override_data {
  target = data.google_filestore_instance.workspace
  values = {
    file_shares = [{
      name               = "share"
      capacity_gb        = 1024
      nfs_export_options = []
      source_backup      = ""
    }]
    networks = [{
      ip_addresses      = ["10.0.0.2"]
      connect_mode      = "DIRECT_PEERING"
      modes             = ["MODE_IPV4"]
      network           = "default"
      reserved_ip_range = ""
    }]
  }
}

override_data {
  target = data.google_secret_manager_secret_version.master_secret
  values = {
    secret_data = "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIzNDU2Nzg5MDE="
  }
}

run "batch_zones_default_keeps_cluster_zone_only" {
  # apply against the mock providers: the chart values are unknown at plan.
  command = apply

  assert {
    condition     = !contains(keys(yamldecode(kubectl_manifest.batch_compute_class.yaml_body).spec), "priorityDefaults")
    error_message = "empty batch_zones must not set spec.priorityDefaults"
  }

  assert {
    condition     = yamldecode(nonsensitive(helm_release.platforma[0].values[0])).kueue.provisioningRequest.enabled == true
    error_message = "ProvisioningRequest admission must stay on by default"
  }
}

run "batch_zones_set_spreads_compute_class" {
  # apply against the mock providers: the chart values are unknown at plan.
  command = apply

  variables {
    batch_zones                        = ["us-central1-a", "us-central1-b", "us-central1-f"]
    kueue_provisioning_request_enabled = false
  }

  assert {
    condition     = yamldecode(kubectl_manifest.batch_compute_class.yaml_body).spec.priorityDefaults.location.zones == ["us-central1-a", "us-central1-b", "us-central1-f"]
    error_message = "batch_zones must land in spec.priorityDefaults.location.zones"
  }

  assert {
    condition     = length(yamldecode(kubectl_manifest.batch_compute_class.yaml_body).spec.priorities) > 0
    error_message = "priorities must still be rendered next to priorityDefaults"
  }

  assert {
    condition     = yamldecode(nonsensitive(helm_release.platforma[0].values[0])).kueue.provisioningRequest.enabled == false
    error_message = "kueue_provisioning_request_enabled = false must reach the chart"
  }
}

run "batch_zones_outside_region_rejected" {
  command = plan

  variables {
    batch_zones = ["us-central1-a", "europe-west1-b"]
  }

  expect_failures = [
    kubectl_manifest.batch_compute_class,
  ]
}

run "batch_zones_malformed_rejected" {
  command = plan

  variables {
    batch_zones = ["us-central1"]
  }

  expect_failures = [
    var.batch_zones,
  ]
}
