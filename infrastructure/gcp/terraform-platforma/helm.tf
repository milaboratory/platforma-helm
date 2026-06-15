# =============================================================================
# Cluster-level controllers: Kueue + AppWrapper
# =============================================================================

resource "helm_release" "kueue" {
  name             = "kueue"
  repository       = "oci://registry.k8s.io/kueue/charts"
  chart            = "kueue"
  version          = var.kueue_version
  namespace        = "kueue-system"
  create_namespace = true

  values = [
    yamlencode({
      controllerManager = {
        manager = {
          resources = {
            limits = {
              cpu    = "500m"
              memory = "1Gi"
            }
            requests = {
              cpu    = "100m"
              memory = "512Mi"
            }
          }
        }
      }
      featureGates = {
        AppWrapper      = true
        ProvisioningACC = true
      }
      integrations = {
        frameworks = [
          "batch/job",
          "jobset.x-k8s.io/jobset",
          "workload.codeflare.dev/appwrapper",
        ]
        podOptions = {
          namespaceSelector = {
            matchExpressions = [{
              key      = "kubernetes.io/metadata.name"
              operator = "NotIn"
              values   = ["kube-system", "kueue-system"]
            }]
          }
        }
      }
      metrics = {
        enableClusterQueueResources = true
      }
    })
  ]

  # No depends_on needed — the cluster (with its node pools) is fully
  # provisioned by the infra module before this module runs.
}

# AppWrapper — no official Helm chart on a registry; upstream ships install.yaml.
# We fetch it via http data source and apply as multi-doc via kubectl provider.
data "http" "appwrapper_manifest" {
  url = "https://github.com/project-codeflare/appwrapper/releases/download/${var.appwrapper_version}/install.yaml"
}

# Verify the fetched manifest matches the expected SHA-256. A compromised
# release tag, MITM in transit, or a silent upstream re-tag would change
# the hash and fail this assertion before kubectl_manifest tries to apply
# anything to the cluster.
resource "terraform_data" "appwrapper_manifest_integrity" {
  input = sha256(data.http.appwrapper_manifest.response_body)

  lifecycle {
    postcondition {
      condition     = self.input == var.appwrapper_install_yaml_sha256
      error_message = "AppWrapper install.yaml SHA-256 mismatch — got ${self.input}, expected ${var.appwrapper_install_yaml_sha256}. Either upstream re-published the release at ${var.appwrapper_version} (verify and update var.appwrapper_install_yaml_sha256) or the download was tampered with."
    }
  }
}

data "kubectl_file_documents" "appwrapper" {
  content = data.http.appwrapper_manifest.response_body
}

resource "kubectl_manifest" "appwrapper" {
  # Data source resolves at plan time so for_each keys are known.
  # The integrity check (terraform_data.appwrapper_manifest_integrity)
  # is depended-on at the resource level instead of on the data source,
  # so terraform gates the kubectl apply on the SHA-256 verification
  # passing without making the data source's outputs unknown at plan time.
  for_each = data.kubectl_file_documents.appwrapper.manifests

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.kueue,
    terraform_data.appwrapper_manifest_integrity,
  ]
}
