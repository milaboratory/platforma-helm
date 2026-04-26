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
            serviceAccount = google_service_account.server.email
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
}

resource "kubernetes_namespace" "platforma" {
  metadata {
    name = var.platforma_namespace
  }

  depends_on = [
    google_container_node_pool.system,
  ]
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

  depends_on = [google_project_service.enabled]
}

resource "google_secret_manager_secret_version" "admin_password" {
  secret      = google_secret_manager_secret.admin_password.id
  secret_data = random_password.admin.result
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

  name      = var.helm_release_name
  chart     = "${path.module}/../../../charts/platforma"
  namespace = kubernetes_namespace.platforma.metadata[0].name

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
            instanceName = google_filestore_instance.workspace.name
            location     = google_filestore_instance.workspace.location
            shareName    = google_filestore_instance.workspace.file_shares[0].name
            ip           = google_filestore_instance.workspace.networks[0].ip_addresses[0]
            path         = "/"
          }
        }
        main = {
          type = "gcs"
          gcs = {
            bucket         = google_storage_bucket.primary.name
            projectId      = var.project_id
            serviceAccount = google_service_account.server.email
          }
        }
      }

      auth = {
        htpasswd = {
          credentials = [{
            username = var.admin_username
            password = random_password.admin.result
          }]
        }
      }

      license = {
        secretName = kubernetes_secret.license.metadata[0].name
        secretKey  = "MI_LICENSE"
      }

      serviceAccount = {
        create = true
        annotations = {
          "iam.gke.io/gcp-service-account" = google_service_account.server.email
        }
      }

      jobServiceAccount = {
        create = true
        annotations = {
          "iam.gke.io/gcp-service-account" = google_service_account.jobs.email
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
            nodeSelector = {
              role = "batch"
            }
            tolerations = [{
              key    = "dedicated"
              value  = "batch"
              effect = "NoSchedule"
            }]
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
        resources = {
          requests = {
            cpu    = 2
            memory = "8Gi"
          }
          limits = {
            cpu    = 4
            memory = "12Gi"
          }
        }
        nodeSelector = {
          role = "system"
        }
        logging = {
          persistence = {
            enabled = false
          }
        }
        debug = {
          enabled = true
        }
      }
      }
    ))
  ]

  timeout = 600

  depends_on = [
    helm_release.kueue,
    kubectl_manifest.appwrapper,
    google_filestore_instance.workspace,
    google_service_account_iam_member.server_wi,
    google_service_account_iam_member.jobs_wi,
    google_storage_bucket_iam_member.server_bucket_admin,
    google_storage_bucket_iam_member.jobs_bucket_admin,
    kubernetes_secret.license,
  ]
}
