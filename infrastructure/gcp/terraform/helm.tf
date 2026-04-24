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
        AppWrapper     = true
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

  depends_on = [
    google_container_node_pool.system,
  ]
}

# AppWrapper — no official Helm chart on a registry; upstream ships install.yaml.
# We fetch it via http data source and apply as multi-doc via kubectl provider.
data "http" "appwrapper_manifest" {
  url = "https://github.com/project-codeflare/appwrapper/releases/download/${var.appwrapper_version}/install.yaml"
}

data "kubectl_file_documents" "appwrapper" {
  content = data.http.appwrapper_manifest.response_body
}

resource "kubectl_manifest" "appwrapper" {
  for_each = data.kubectl_file_documents.appwrapper.manifests

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.kueue,
  ]
}
