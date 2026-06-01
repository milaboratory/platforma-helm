# =============================================================================
# In-cluster controllers
# =============================================================================
# Reproduces the CodeBuild HelmDeployer steps from cloudformation-eks-1-35.yaml
# declaratively:
#   1. ProvisioningRequest CRD  (kubectl_manifest from the autoscaler release)
#   2. Kueue + AppWrapper        (Helm OCI + verified multi-doc install.yaml)
#   3. Cluster Autoscaler        (Helm + ProvisioningRequest RBAC)
#   4. External DNS              (Helm, ingress-gated)
#   5. ALB Controller            (Helm, ingress-gated, after External DNS)
#
# Versions are duplicated from the CloudFormation template; keep them in sync.
# =============================================================================

locals {
  kubernetes_version = "1.35"

  kueue_version              = "0.16.1"
  appwrapper_version         = "v1.2.0"
  cluster_autoscaler_version = "9.56.0"
  external_dns_version       = "1.20.0"
  alb_controller_version     = "3.0.0"

  # SHA-256 of the AppWrapper install.yaml for appwrapper_version. A re-tagged
  # release or a tampered download changes this and fails the apply before any
  # manifest reaches the cluster. Recompute on version bump: curl -fsSL <url> | sha256sum
  appwrapper_install_sha256 = "aabb84a8719248c1dfaa6516f194dce559043237657cc697823f61ebeeaf9024"

  provisioning_request_crd_url = "https://raw.githubusercontent.com/kubernetes/autoscaler/cluster-autoscaler-${local.kubernetes_version}.0/cluster-autoscaler/apis/config/crd/autoscaling.x-k8s.io_provisioningrequests.yaml"
  appwrapper_install_url       = "https://github.com/project-codeflare/appwrapper/releases/download/${local.appwrapper_version}/install.yaml"

  cluster_vpc_id = data.aws_eks_cluster.this.vpc_config[0].vpc_id
}

# Namespace shared by Platforma and the in-cluster controllers (CA, External
# DNS, ALB). Created here (not via helm create_namespace) so multiple releases
# can target it without racing, and so it exists even when deploy_platforma=false.
resource "kubernetes_namespace" "platforma" {
  metadata {
    name = var.platforma_namespace
  }
}

# -----------------------------------------------------------------------------
# 1. ProvisioningRequest CRD — must exist before Kueue starts (Kueue only wires
#    up its provisioning controller if the CRD is present at boot) and before
#    the Cluster Autoscaler runs with --enable-provisioning-requests.
# -----------------------------------------------------------------------------
data "http" "provisioning_request_crd" {
  url = local.provisioning_request_crd_url
}

resource "kubectl_manifest" "provisioning_request_crd" {
  yaml_body         = data.http.provisioning_request_crd.response_body
  server_side_apply = true
}

# -----------------------------------------------------------------------------
# 2a. Kueue (OCI chart). featureGates.AppWrapper wires Kueue to admit the
#     AppWrapper framework installed below.
# -----------------------------------------------------------------------------
resource "helm_release" "kueue" {
  name             = "kueue"
  repository       = "oci://registry.k8s.io/kueue/charts"
  chart            = "kueue"
  version          = local.kueue_version
  namespace        = "kueue-system"
  create_namespace = true

  atomic  = true
  timeout = 300

  values = [yamlencode({
    controllerManager = {
      manager = {
        resources = {
          limits   = { cpu = "500m", memory = "1Gi" }
          requests = { cpu = "100m", memory = "512Mi" }
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
  })]

  depends_on = [kubectl_manifest.provisioning_request_crd]
}

# -----------------------------------------------------------------------------
# 2b. AppWrapper — applied from the upstream multi-doc install.yaml after a
#     SHA-256 integrity gate. The validating/mutating webhook configurations are
#     filtered out (CF deletes them post-install): Platforma drives AppWrapper
#     through Kueue and the admission webhooks are unwanted.
# -----------------------------------------------------------------------------
data "http" "appwrapper_install" {
  url = local.appwrapper_install_url
}

resource "terraform_data" "appwrapper_verified" {
  input = local.appwrapper_install_sha256

  lifecycle {
    precondition {
      condition     = sha256(data.http.appwrapper_install.response_body) == local.appwrapper_install_sha256
      error_message = "AppWrapper install.yaml SHA-256 mismatch for ${local.appwrapper_version}. Upstream may have re-published the release (verify and update appwrapper_install_sha256 in controllers.tf) or the download was tampered with."
    }
  }
}

data "kubectl_file_documents" "appwrapper" {
  content = data.http.appwrapper_install.response_body
}

locals {
  appwrapper_manifests = {
    for k, v in data.kubectl_file_documents.appwrapper.manifests : k => v
    if !contains(["ValidatingWebhookConfiguration", "MutatingWebhookConfiguration"], try(yamldecode(v).kind, ""))
  }
}

resource "kubectl_manifest" "appwrapper" {
  for_each = local.appwrapper_manifests

  yaml_body         = each.value
  server_side_apply = true

  depends_on = [
    terraform_data.appwrapper_verified,
    helm_release.kueue,
  ]
}

# -----------------------------------------------------------------------------
# 3. Cluster Autoscaler (ProvisioningRequest expander). Auto-discovers node
#    groups by the eks:cluster-name tag EKS applies to managed node-group ASGs.
# -----------------------------------------------------------------------------
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = local.cluster_autoscaler_version
  namespace  = var.platforma_namespace

  atomic  = true
  timeout = 300

  values = [yamlencode({
    image = {
      tag = "v${local.kubernetes_version}.0"
    }
    autoDiscovery = {
      clusterName = var.cluster_name
      tags        = ["eks:cluster-name=${var.cluster_name}"]
    }
    awsRegion = var.region
    rbac = {
      serviceAccount = {
        create = true
        name   = "cluster-autoscaler"
        annotations = {
          "eks.amazonaws.com/role-arn" = local.autoscaler_role_arn
        }
      }
    }
    extraArgs = {
      "scale-down-delay-after-add"          = "5m"
      "scale-down-unneeded-time"            = "5m"
      "scale-down-utilization-threshold"    = "0.5"
      "expander"                            = "least-waste"
      "max-node-provision-time"             = "5m"
      "initial-node-group-backoff-duration" = "1m"
      "max-node-group-backoff-duration"     = "5m"
      "enable-provisioning-requests"        = "true"
      "kube-api-content-type"               = "application/json"
      "startup-taint"                       = "nvidia.com/gpu-not-ready"
    }
  })]

  # helm_release.kueue: Kueue's Deployment admission webhook (failurePolicy=Fail)
  # intercepts Deployments in this namespace. Until Kueue's pod is serving, those
  # creates are rejected ("no endpoints available for kueue-webhook-service"), so
  # every Deployment-creating controller here must wait for Kueue. CF gets this
  # ordering for free from sequential CodeBuild steps; Terraform parallelizes.
  depends_on = [
    kubernetes_namespace.platforma,
    kubectl_manifest.provisioning_request_crd,
    helm_release.kueue,
  ]
}

# Grant the Cluster Autoscaler access to ProvisioningRequest + PodTemplate
# objects (the CA chart's RBAC predates ProvisioningRequest support).
resource "kubernetes_cluster_role" "ca_provisioning_requests" {
  metadata {
    name = "cluster-autoscaler-provisioning-requests"
  }

  rule {
    api_groups = ["autoscaling.x-k8s.io"]
    resources  = ["provisioningrequests", "provisioningrequests/status"]
    verbs      = ["get", "list", "watch", "create", "update", "patch", "delete"]
  }

  rule {
    api_groups = [""]
    resources  = ["podtemplates"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_cluster_role_binding" "ca_provisioning_requests" {
  metadata {
    name = "cluster-autoscaler-provisioning-requests"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = kubernetes_cluster_role.ca_provisioning_requests.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "cluster-autoscaler"
    namespace = var.platforma_namespace
  }

  depends_on = [helm_release.cluster_autoscaler]
}

# -----------------------------------------------------------------------------
# 4. External DNS (ingress only). Manages the A record for the Platforma host in
#    the configured Route53 zone. Installed before the ALB controller to avoid a
#    mutating-webhook race during the first ingress reconcile.
# -----------------------------------------------------------------------------
resource "helm_release" "external_dns" {
  count = var.ingress_enabled ? 1 : 0

  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = local.external_dns_version
  namespace  = var.platforma_namespace

  atomic  = true
  timeout = 180

  values = [yamlencode({
    policy     = "sync"
    registry   = "txt"
    txtOwnerId = var.cluster_name
    extraArgs  = ["--zone-id-filter=${var.route53_zone_id}"]
    serviceAccount = {
      create = true
      name   = "external-dns"
      annotations = {
        "eks.amazonaws.com/role-arn" = local.external_dns_role_arn
      }
    }
  })]

  # helm_release.kueue: see cluster_autoscaler — Kueue's Deployment webhook gates
  # Deployment creation in this namespace until Kueue is serving.
  depends_on = [
    kubernetes_namespace.platforma,
    helm_release.kueue,
  ]
}

# -----------------------------------------------------------------------------
# 5. AWS Load Balancer Controller (ingress only). Provisions the ALB for the
#    Platforma ingress. vpcId is read from the cluster so it never drifts.
# -----------------------------------------------------------------------------
resource "helm_release" "alb_controller" {
  count = var.ingress_enabled ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = local.alb_controller_version
  namespace  = var.platforma_namespace

  atomic  = true
  timeout = 300

  values = [yamlencode({
    clusterName  = var.cluster_name
    region       = var.region
    vpcId        = local.cluster_vpc_id
    replicaCount = 1
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = local.alb_controller_role_arn
      }
    }
  })]

  depends_on = [
    kubernetes_namespace.platforma,
    helm_release.external_dns,
    helm_release.kueue, # see cluster_autoscaler — Kueue Deployment webhook gating
  ]
}
