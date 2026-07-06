# =============================================================================
# Platforma namespace, auto-generated admin password, Helm release
# =============================================================================

# -----------------------------------------------------------------------------
# Data libraries — combine demo library (if enabled) with user-supplied list,
# render as Helm `dataSources` values and create K8s Secrets for S3 entries
# that carry credentials.
# -----------------------------------------------------------------------------
locals {
  # MiLaboratories' demo data library — same AWS S3 bucket the AWS CF stack
  # uses, mounted cross-cloud from GKE. Credentials are public (read-only IAM
  # user on a public dataset bucket — same pattern as AWS CF embeds).
  demo_data_library = var.enable_demo_data_library ? [{
    name              = "milabs-demo-data"
    type              = "s3"
    bucket            = "milab-euce1-prod-eks-s3-farm-library"
    prefix            = ""
    project_id        = ""
    region            = "eu-central-1"
    endpoint          = ""
    external_endpoint = ""
    access_key        = "AKIAXOL6R5EBCOHXV7PC"
    secret_key        = "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"
  }] : []

  all_data_libraries = concat(var.data_libraries, local.demo_data_library)

  s3_libraries_with_creds = {
    for lib in local.all_data_libraries : lib.name => lib
    if lib.type == "s3" && lib.access_key != ""
  }

  helm_data_sources = [
    for lib in local.all_data_libraries : merge(
      {
        name = lib.name
        type = lib.type
      },
      lib.type == "gcs" ? {
        gcs = merge(
          { bucket = lib.bucket },
          lib.prefix != "" ? { prefix = lib.prefix } : {},
          # projectId + serviceAccount are required by the Platforma binary for any
          # GCS data source. For same-project buckets the user can omit project_id
          # in their var.data_libraries entry — we default it to the cluster project
          # and use the server's Workload Identity SA. For cross-project public
          # buckets (like the demo library) the same defaults work because GCP
          # uses the SA only to sign requests; anonymous read still works.
          {
            projectId      = lib.project_id != "" ? lib.project_id : var.project_id
            serviceAccount = data.google_service_account.server.email
          },
        )
      } : {},
      lib.type == "s3" ? {
        s3 = merge(
          { bucket = lib.bucket },
          lib.prefix != "" ? { prefix = lib.prefix } : {},
          lib.region != "" ? { region = lib.region } : {},
          lib.endpoint != "" ? { endpoint = lib.endpoint } : {},
          lib.external_endpoint != "" ? { externalEndpoint = lib.external_endpoint } : {},
          lib.access_key != "" ? {
            secretRef = {
              name           = "platforma-datasource-${lib.name}"
              accessKeyField = "access-key"
              secretKeyField = "secret-key"
            }
          } : {},
        )
      } : {},
    )
  ]

  # Image override → split repo:tag or just repo (let chart fill tag from appVersion)
  image_override_parts = var.platforma_image_override != "" ? split(":", var.platforma_image_override) : []

  # Auth Helm values — branches on auth_method:
  #   ldap                                → ldap.* block
  #   htpasswd + htpasswd_content         → reference user-supplied secret
  #   htpasswd + empty content (auto-gen) → inline credentials list with random_password
  #
  # Built via merge() of mutually-exclusive single-key objects rather than a
  # straight ternary because Terraform 1.5 strictly unifies conditional branch
  # types — the htpasswd content path produces {secretName, secretKey} while
  # the auto-gen path produces {credentials = [...]}. merge with empty-object
  # fallbacks sidesteps the unify check.
  _auth_ldap = {
    ldap = merge(
      {
        server      = var.ldap_server
        startTLS    = var.ldap_start_tls
        bindDN      = var.ldap_bind_dn
        searchRules = var.ldap_search_rules
        searchUser  = var.ldap_search_user
      },
      var.ldap_search_password != "" ? {
        searchPasswordSecretRef = {
          name = "platforma-ldap-search-password"
          key  = "password"
        }
      } : {},
    )
  }

  _auth_htpasswd_content = {
    htpasswd = {
      secretName = "platforma-htpasswd-provided"
      secretKey  = "htpasswd"
    }
  }

  _auth_htpasswd_auto = {
    htpasswd = {
      credentials = [{
        username = var.admin_username
        password = random_password.admin.result
      }]
    }
  }

  auth_helm_value = merge(
    { showUserList = var.show_user_list },
    (var.auth_method == "ldap") ? local._auth_ldap : {},
    (var.auth_method == "htpasswd" && var.htpasswd_content != "") ? local._auth_htpasswd_content : {},
    (var.auth_method == "htpasswd" && var.htpasswd_content == "") ? local._auth_htpasswd_auto : {},
  )
}

resource "kubernetes_namespace" "platforma" {
  metadata {
    name = var.platforma_namespace
  }
  # No depends_on needed — install.sh applies the infra module (which creates
  # the system node pool) before this module, so the cluster is fully ready
  # by the time we plan here.
}

# Auto-generated admin password, stored in Secret Manager for retrieval.
resource "random_password" "admin" {
  length           = 24
  special          = true
  override_special = "-_.!@#%^*+=?"
}

resource "google_secret_manager_secret" "admin_password" {
  secret_id = "${var.cluster_name}-admin-password"
  project   = var.project_id

  replication {
    auto {}
  }
  # secretmanager.googleapis.com is enabled by the infra module.
}

resource "google_secret_manager_secret_version" "admin_password" {
  secret      = google_secret_manager_secret.admin_password.id
  secret_data = random_password.admin.result
}

# =============================================================================
# Master secret for Platforma security layer. 
# Stored in Secret Manager (KMS-encrypted),
# materialized as a Kubernetes Secret consumed by the chart via
# masterSecret.secretName. Generated once and reused across applies via
# Terraform state — destroy rotates it (same trade-off as admin_password).
# =============================================================================

# BYO support: when var.master_secret_secret_id is set, read the value from
# Secret Manager via the Google provider. Only the secret *name* travels
# through tfvars / the IM bundle; the value never leaves Secret Manager except
# into TF state.
#
# When unset, random_id generates a fresh 256-bit base64 value on first apply;
# its result is persisted in TF state, so subsequent applies don't rotate it.
# Single path: Secret Manager is the source of truth. install.sh pre-creates
# the secret + initial version (random on first run, MASTER_SECRET env value
# when the operator wants to pin or rotate). TF reads the latest version via
# the Google provider — no gcloud dependency, no value in tfvars or the IM
# bundle, stable across TF state loss.
data "google_secret_manager_secret_version" "master_secret" {
  secret  = var.master_secret_secret_id
  project = var.project_id
}

locals {
  master_secret_value = data.google_secret_manager_secret_version.master_secret.secret_data
}

resource "kubernetes_secret" "master_secret" {
  metadata {
    name      = "platforma-master-secret"
    namespace = kubernetes_namespace.platforma.metadata[0].name
  }

  data = {
    "master-secret" = local.master_secret_value
  }

  type = "Opaque"

  # Surface short / non-base64 BYO master secrets at plan time. The Platforma
  # backend base64-decodes this field and rejects anything < 32 raw bytes at
  # pod startup; without this check the failure shows up ~15 min into a Helm
  # install (after image pull + PVC bind) and gets atomic-rolled back, taking
  # the pod's logs with it.
  #
  # We deliberately do NOT call base64decode() here — OpenTofu's
  # base64decode requires the decoded result to be valid UTF-8, and random
  # 32-byte master secrets almost never are. Instead we (a) check the value
  # matches base64 alphabet + padding, then (b) compute decoded length
  # arithmetically as floor(len*3/4) - padding_count.
  lifecycle {
    precondition {
      condition = (
        can(regex("^[A-Za-z0-9+/]*={0,2}$", local.master_secret_value))
        && floor(length(local.master_secret_value) * 3 / 4)
        -length(regexall("=", local.master_secret_value)) >= 32
      )
      error_message = <<-EOT
        Platforma master secret must be base64-encoded with at least 32 raw bytes of payload after decoding.
        The current value (from Secret Manager secret ${var.cluster_name}-platforma-master-secret) is too short or not valid base64.
        To rotate, either:
          - delete the Secret Manager secret so terraform regenerates it:
              gcloud secrets delete ${var.cluster_name}-platforma-master-secret --project=${var.project_id}
            (then re-run tofu apply), or
          - replace it with a fresh value:
              openssl rand -base64 32 | gcloud secrets versions add \
                ${var.cluster_name}-platforma-master-secret --project=${var.project_id} --data-file=-
      EOT
    }
  }
}

# =============================================================================
# Auth: htpasswd-content secret (when user supplied bcrypted content) or
# LDAP search-password secret (when ldap with search bind). The auto-gen
# htpasswd path uses random_password.admin + Secret Manager (above); the
# Helm chart creates its own htpasswd Secret from the credentials list.
# =============================================================================

resource "kubernetes_secret" "htpasswd_provided" {
  count = (var.auth_method == "htpasswd" && var.htpasswd_content != "") ? 1 : 0

  metadata {
    name      = "platforma-htpasswd-provided"
    namespace = kubernetes_namespace.platforma.metadata[0].name
  }

  data = {
    htpasswd = var.htpasswd_content
  }

  type = "Opaque"
}

resource "kubernetes_secret" "ldap_search_password" {
  count = (var.auth_method == "ldap" && var.ldap_search_password != "") ? 1 : 0

  metadata {
    name      = "platforma-ldap-search-password"
    namespace = kubernetes_namespace.platforma.metadata[0].name
  }

  data = {
    password = var.ldap_search_password
  }

  type = "Opaque"
}

# License secret (chart expects an existing secret via license.secretName).
resource "kubernetes_secret" "license" {
  metadata {
    name      = "platforma-license"
    namespace = kubernetes_namespace.platforma.metadata[0].name
  }

  data = {
    MI_LICENSE = var.license_key
  }

  type = "Opaque"
}

# Per-S3-library credential secrets (for cross-account / non-Workload-Identity access).
resource "kubernetes_secret" "data_library" {
  for_each = local.s3_libraries_with_creds

  metadata {
    name      = "platforma-datasource-${each.value.name}"
    namespace = kubernetes_namespace.platforma.metadata[0].name
  }

  data = {
    "access-key" = each.value.access_key
    "secret-key" = each.value.secret_key
  }

  type = "Opaque"
}

# Platforma Helm release. Gated on var.deploy_platforma so users can stand up
# infrastructure + cluster controllers (Kueue, AppWrapper) for testing without
# the application — useful for isolating infra issues from app issues.
resource "helm_release" "platforma" {
  count = var.deploy_platforma ? 1 : 0

  name = var.helm_release_name
  # Chart source: local path by default (the chart that ships with this
  # repo). When helm_chart_repository is set, pull from that OCI registry
  # instead — typical use is the GAR helm repo provisioned in
  # helm_registry.tf for fast iteration on chart changes during a GCP
  # deployment.
  repository = var.helm_chart_repository != "" ? var.helm_chart_repository : null
  chart      = var.helm_chart_repository != "" ? "platforma" : "${path.module}/../../../charts/platforma"
  version    = var.helm_chart_repository != "" && var.platforma_chart_version != "" ? var.platforma_chart_version : null
  namespace  = kubernetes_namespace.platforma.metadata[0].name

  # Cluster-specific values computed from Terraform state.
  values = [
    yamlencode(merge(
      length(local.image_override_parts) > 0 ? {
        image = merge(
          { repository = local.image_override_parts[0] },
          length(local.image_override_parts) > 1 ? { tag = local.image_override_parts[1] } : {},
        )
      } : {},
      { dataSources = local.helm_data_sources },
      {
        environment = "gcp"

        storage = {
          database = {
            size         = "50Gi"
            storageClass = "premium-rwo"
          }
          workspace = {
            filestore = {
              enabled      = true
              instanceName = data.google_filestore_instance.workspace.name
              location     = data.google_filestore_instance.workspace.location
              shareName    = data.google_filestore_instance.workspace.file_shares[0].name
              ip           = data.google_filestore_instance.workspace.networks[0].ip_addresses[0]
              path         = "/"
            }
          }
          main = {
            type = "gcs"
            gcs = {
              bucket         = data.google_storage_bucket.primary.name
              projectId      = var.project_id
              serviceAccount = data.google_service_account.server.email
            }
          }
        }

        auth = local.auth_helm_value

        masterSecret = {
          secretName = kubernetes_secret.master_secret.metadata[0].name
          secretKey  = "master-secret"
        }

        license = {
          secretName = kubernetes_secret.license.metadata[0].name
          secretKey  = "MI_LICENSE"
        }

        serviceAccount = {
          create = true
          annotations = {
            "iam.gke.io/gcp-service-account" = data.google_service_account.server.email
          }
        }

        jobServiceAccount = {
          create = true
          annotations = {
            "iam.gke.io/gcp-service-account" = data.google_service_account.jobs.email
          }
        }

        # Chart's built-in ingress disabled — we provision a GKE Gateway + HTTPRoute
        # externally in dns_tls.tf when var.ingress_enabled = true.
        ingress = {
          enabled = false
        }

        kueue = {
          mode = "dedicated"
          maxJobResources = {
            cpu    = local.effective_kueue_max_job_cpu
            memory = local.effective_kueue_max_job_memory
          }
          pools = {
            ui = {
              nodeSelector = {
                role = "ui"
              }
              tolerations = [{
                key    = "dedicated"
                value  = "ui"
                effect = "NoSchedule"
              }]
            }
            batch = {
              # Batch pods select the custom ComputeClass (computeclass.tf),
              # which provisions highmem nodes on demand (n2d-highmem-64,
              # falling back to n2-highmem-64 on stockout). This nodeSelector
              # both ATTRACTS batch pods to ComputeClass nodes and triggers
              # the class's node-pool auto-creation. The taint set on the
              # class nodes plus this toleration isolates batch work from
              # system/ui pods.
              nodeSelector = {
                "cloud.google.com/compute-class" = "platforma-batch"
              }
              tolerations = [{
                key    = "dedicated"
                value  = "batch"
                effect = "NoSchedule"
              }]
            }
            # GPU pool not provisioned by the GCP module (no GPU node pool in
            # gke.tf). Disable so the chart skips the nvidia-device-plugin
            # DaemonSet, GPU ResourceFlavor + ClusterQueue, and the
            # --runner-gpu-available=enabled flag. Add a GPU pool to gke.tf
            # before flipping this back on — and set maxJobResources.gpuMemory
            # to the largest VRAM available on a single GPU node (chart fails
            # to render otherwise).
            gpu = {
              enabled = false
            }
          }
          dedicated = {
            resources = {
              ui = {
                cpu    = 16
                memory = "64Gi"
              }
              batch = {
                cpu    = local.effective_kueue_batch_queue_cpu
                memory = local.effective_kueue_batch_queue_memory
              }
            }
          }
        }

        app = {
          # Resource sizing mirrors AWS CloudFormation (cloudformation-eks-1-35.yaml
          # platforma-values.yaml block): 4 CPU / 16 GiB requested, 8 CPU / 32 GiB
          # limit. CPU limit > request lets platforma burst on bursty workflow
          # scheduling; memory limit > request gives burst headroom before the
          # kernel OOM-kills under spikes.
          #
          # On the default system_pool_machine_type (n2d-standard-8, ~26 GiB
          # allocatable) the effective memory ceiling is node allocatable, not
          # the 32 GiB limit — a single pod can't actually grow past the node.
          # To realize the full 32 GiB burst, bump system_pool_machine_type to
          # n2d-standard-16 (~58 GiB allocatable).
          resources = {
            requests = {
              cpu    = 4
              memory = "16Gi"
            }
            limits = {
              cpu    = 8
              memory = "32Gi"
            }
          }
          nodeSelector = {
            role = "system"
          }
          # Inherit chart defaults: app.debug.enabled = false (production log
          # level, debug API still bound to localhost via chart default) and
          # app.logging.persistence.enabled = true (20Gi PVC with rotation,
          # mirrors the EBS log volume on the AWS CloudFormation path).
          #
          # Tell the GKE Gateway controller to forward to the gRPC port over
          # HTTP/2 cleartext. Without this the controller defaults to HTTP/1.1
          # and the gRPC backend rejects, marking it unhealthy. Replaces the
          # parallel platforma-grpc Service we used to provision in
          # dns_tls.tf — chart-side knob is the supported path now that
          # values.yaml exposes app.serviceAppProtocols.
          serviceAppProtocols = {
            grpc = "kubernetes.io/h2c"
          }
        }
      }
    ))
  ]

  # Apply on both install/upgrade and uninstall. Bumped from 600 (10 min)
  # because uninstall can stretch when DaemonSet pods (e.g.
  # nvidia-device-plugin) finish their preStop hooks slowly and PVCs unbind —
  # 10 min was hit in IM destroys, leaving the helm release stuck and
  # downstream certmap deletion racing the gateway-controller cleanup.
  timeout = 1800

  # Cross-module dependencies (Filestore, Workload Identity bindings, GCS
  # IAM) are guaranteed by install.sh applying the infra module first.
  depends_on = [
    helm_release.kueue,
    kubectl_manifest.appwrapper_namespace,
    kubectl_manifest.appwrapper,
    kubernetes_secret.license,
    kubernetes_secret.htpasswd_provided,
    kubernetes_secret.ldap_search_password,
    kubernetes_secret.master_secret,
  ]
}
