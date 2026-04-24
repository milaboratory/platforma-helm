# =============================================================================
# Platforma namespace, auto-generated admin password, Helm release
# =============================================================================

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

# Platforma Helm release.
resource "helm_release" "platforma" {
  name      = var.helm_release_name
  chart     = "${path.module}/../../../charts/platforma"
  namespace = kubernetes_namespace.platforma.metadata[0].name

  # Cluster-specific values computed from Terraform state.
  values = [
    yamlencode({
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

      ingress = {
        enabled = var.ingress_enabled
      }

      kueue = {
        mode = "dedicated"
        maxJobResources = {
          cpu    = var.kueue_max_job_cpu
          memory = var.kueue_max_job_memory
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
              cpu    = var.kueue_batch_queue_cpu
              memory = var.kueue_batch_queue_memory
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
    })
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
