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

    # A replace() that matches nothing fails silently, which would leave the
    # buggy upstream controller running while the configuration claims
    # otherwise. Fail loudly instead. The upstream reference appears exactly
    # once, on the manager container.
    postcondition {
      condition     = var.appwrapper_image == "" || length(split(local.appwrapper_upstream_image, data.http.appwrapper_manifest.response_body)) == 2
      error_message = "var.appwrapper_image is set, but '${local.appwrapper_upstream_image}' was not found exactly once in the upstream install.yaml, so the image override would not apply as intended. Upstream may have changed how the image is referenced at ${var.appwrapper_version}."
    }

    # Same reasoning for the controller resources block.
    postcondition {
      condition     = length(split(local.appwrapper_upstream_resources, data.http.appwrapper_manifest.response_body)) == 2
      error_message = "The AppWrapper controller resources block was not found exactly once in the upstream install.yaml, so the memory override would not apply. Upstream likely changed the manager container's requests or limits at ${var.appwrapper_version} — compare against local.appwrapper_upstream_resources and update it."
    }
  }
}

# Substitute the controller image for our patched build (see var.appwrapper_image)
# and raise the controller's memory (see var.appwrapper_controller_memory_limit).
# The SHA-256 assertion above runs against the ORIGINAL response body, so upstream
# integrity is verified before anything is rewritten — we only substitute once the
# manifest is known-good. Everything else in the install (CRDs, RBAC, webhooks,
# namespace) is applied exactly as upstream ships it.
locals {
  appwrapper_upstream_image = "quay.io/ibm/appwrapper:${var.appwrapper_version}"

  # The manager container's resources exactly as upstream v1.2.0 ships them.
  # Written out line by line rather than as a heredoc because the leading
  # whitespace is load-bearing — it has to match the manifest byte for byte.
  appwrapper_upstream_resources = join("\n", [
    "        resources:",
    "          limits:",
    "            cpu: \"2\"",
    "            memory: 128Mi",
    "          requests:",
    "            cpu: 100m",
    "            memory: 64Mi",
  ])

  appwrapper_patched_resources = join("\n", [
    "        resources:",
    "          limits:",
    "            cpu: \"2\"",
    "            memory: ${var.appwrapper_controller_memory_limit}",
    "          requests:",
    "            cpu: 100m",
    "            memory: ${var.appwrapper_controller_memory_request}",
  ])

  appwrapper_manifest_with_image = (
    var.appwrapper_image == ""
    ? data.http.appwrapper_manifest.response_body
    : replace(data.http.appwrapper_manifest.response_body, local.appwrapper_upstream_image, var.appwrapper_image)
  )

  appwrapper_manifest_body = replace(
    local.appwrapper_manifest_with_image,
    local.appwrapper_upstream_resources,
    local.appwrapper_patched_resources,
  )
}

data "kubectl_file_documents" "appwrapper" {
  content = local.appwrapper_manifest_body
}

# The appwrapper namespace must exist before the 17 other manifests inside it
# (configmap, serviceaccount, webhooks, deployment, ...) can apply. Terraform
# parallelises kubectl_manifest for_each across all manifests in the install
# YAML, so without an explicit gate the first apply races — typically
# `appwrapper-operator-config` is attempted before the namespace exists and
# fails with `namespaces "appwrapper-system" not found`. Pull the namespace
# out as a separate resource and have the rest depend on it.
#
# The manifest key produced by kubectl_file_documents follows the kubectl
# resource path pattern: /api/v1/namespaces/<name>.
locals {
  appwrapper_namespace_key = "/api/v1/namespaces/appwrapper-system"
  appwrapper_other_manifests = {
    for k, v in data.kubectl_file_documents.appwrapper.manifests : k => v
    if k != local.appwrapper_namespace_key
  }
}

# State migration for workspaces that already applied the old single-resource
# layout: rename the for_each instance to the new standalone resource so
# terraform does NOT plan a destroy of the namespace (which would cascade and
# wipe every resource inside it). Remove this block once all environments have
# applied this change.
moved {
  from = kubectl_manifest.appwrapper["/api/v1/namespaces/appwrapper-system"]
  to   = kubectl_manifest.appwrapper_namespace
}

resource "kubectl_manifest" "appwrapper_namespace" {
  yaml_body         = data.kubectl_file_documents.appwrapper.manifests[local.appwrapper_namespace_key]
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.kueue,
    terraform_data.appwrapper_manifest_integrity,
  ]
}

resource "kubectl_manifest" "appwrapper" {
  # Data source resolves at plan time so for_each keys are known.
  # The integrity check (terraform_data.appwrapper_manifest_integrity)
  # is depended-on at the resource level instead of on the data source,
  # so terraform gates the kubectl apply on the SHA-256 verification
  # passing without making the data source's outputs unknown at plan time.
  for_each = local.appwrapper_other_manifests

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true

  depends_on = [
    helm_release.kueue,
    terraform_data.appwrapper_manifest_integrity,
    kubectl_manifest.appwrapper_namespace,
  ]
}
