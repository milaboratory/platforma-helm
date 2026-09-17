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

  # Block software images default to containers.pl-open.science/milaboratories/pl-containers
  # (served from quay.io). Rewrite that prefix to the per-install GAR pull-through cache the
  # infra module creates (terraform-infra/gar.tf), so the cluster pulls from a same-region
  # mirror. Mirrors the AWS ecr_registry local (aws/terraform/platforma/data.tf). The repo id
  # must match terraform-infra: ${resource_name_prefix}-containers.
  image_cache_registry         = "${var.region}-docker.pkg.dev/${var.project_id}/${var.resource_name_prefix}-containers"
  default_docker_registry      = "${local.image_cache_registry}/milaboratories/pl-containers"
  artifact_registry_login_host = "${var.region}-docker.pkg.dev"

  auth_sources = {
    sso = (
      contains(["google", "entra", "oidc"], var.auth_method)
      ? var.auth_method
      : (var.sso_provider == "none" ? "" : var.sso_provider)
    )
    ldap  = var.ldap_server != "" && (var.auth_method == "" || var.auth_method == "ldap")
    local = var.enable_local_users || (var.auth_method == "htpasswd" && nonsensitive(var.htpasswd_content != ""))
  }

  auth_combinable_variables_set = (
    var.sso_provider != "none"
    || var.enable_local_users
    || var.sso_admin_users != ""
    || var.ldap_admin_users != ""
    || var.local_admin_users != ""
  )

  _auth_admin_regexps = {
    for source, patterns in {
      sso   = var.sso_admin_users
      ldap  = var.ldap_admin_users
      local = var.local_admin_users
    } :
    source => [
      for pattern in split(";", patterns) : "admin=login=${trimspace(pattern)}"
      if trimspace(pattern) != ""
    ]
  }

  _auth_entry_google = merge({
    name = "google"
    type = "sso"
    sso = {
      issuer       = "https://accounts.google.com"
      clientId     = var.google_client_id
      scopes       = "openid profile email"
      prompt       = "consent"
      accessType   = "offline"
      clientSecret = { secretName = "platforma-sso-client-secret" }
    }
    map         = { login = "email", email = "email", displayName = "name" }
    lookUpAttr  = "email"
    createUsers = true
    },
    length(local._auth_admin_regexps.sso) > 0 ? { roles = { attrRegexps = local._auth_admin_regexps.sso } } : {},
  )

  _auth_entry_entra = merge({
    name = "entra"
    type = "sso"
    sso = {
      issuer      = "https://login.microsoftonline.com/${var.entra_tenant_id}/v2.0"
      clientId    = var.entra_client_id
      userIdClaim = "oid"
    }
    trustUnverifiedEmail = true
    map                  = { login = "preferred_username", email = "email", displayName = "name", groups = "groups" }
    lookUpAttr           = "email"
    createUsers          = true
    },
    length(local._auth_admin_regexps.sso) > 0 ? { roles = { attrRegexps = local._auth_admin_regexps.sso } } : {},
  )

  _auth_entry_oidc = merge({
    name = "oidc"
    type = "sso"
    sso = {
      issuer      = var.oidc_issuer
      clientId    = var.oidc_client_id
      scopes      = var.oidc_scopes
      resource    = var.oidc_resource
      prompt      = var.oidc_prompt
      userIdClaim = var.oidc_user_id_claim
    }
    map         = { email = "email", displayName = "name", groups = var.oidc_groups_claim }
    lookUpAttr  = "email"
    createUsers = true
    },
    length(local._auth_admin_regexps.sso) > 0 ? { roles = { attrRegexps = local._auth_admin_regexps.sso } } : {},
  )

  _auth_entry_corp = merge({
    name = "corp"
    type = "ldap"
    ldap = merge({
      url         = var.ldap_server
      startTLS    = var.ldap_start_tls
      userDN      = var.ldap_bind_dn
      bindDN      = var.ldap_search_user
      searchRules = var.ldap_search_rules
      },
      var.ldap_search_password != "" ? {
        bindPasswordSecretRef = {
          name = "platforma-ldap-search-password"
          key  = "password"
        }
      } : {},
    )
    createUsers = true
    },
    var.ldap_search_user != "" ? { map = { email = "mail", displayName = "displayName" } } : {},
    length(local._auth_admin_regexps.ldap) > 0 ? { roles = { attrRegexps = local._auth_admin_regexps.ldap } } : {},
  )

  _auth_entry_local = merge({
    name = "local"
    type = "htpasswd"
    htpasswd = {
      secretName = "platforma-htpasswd-provided"
      secretKey  = "htpasswd"
    }
    },
    length(local._auth_admin_regexps.local) > 0 ? { roles = { attrRegexps = local._auth_admin_regexps.local } } : {},
  )

  _auth_entry_admin = {
    name  = "admin"
    type  = "htpasswd"
    title = "Administrator"
    htpasswd = {
      credentials = [{
        username = var.admin_username
        password = random_password.admin.result
      }]
    }
    adminUsers = [var.admin_username]
  }

  auth_providers = concat(
    local.auth_sources.sso == "google" ? [local._auth_entry_google] : [],
    local.auth_sources.sso == "entra" ? [local._auth_entry_entra] : [],
    local.auth_sources.sso == "oidc" ? [local._auth_entry_oidc] : [],
    local.auth_sources.ldap ? [local._auth_entry_corp] : [],
    local.auth_sources.local ? [local._auth_entry_local] : [],
    [local._auth_entry_admin],
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
  count = local.auth_sources.local ? 1 : 0

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
  count = (local.auth_sources.ldap && var.ldap_search_password != "") ? 1 : 0

  metadata {
    name      = "platforma-ldap-search-password"
    namespace = kubernetes_namespace.platforma.metadata[0].name
  }

  data = {
    password = var.ldap_search_password
  }

  type = "Opaque"
}

# SSO client secret (Google requires one even for PKCE). The chart references it
# via auth.sso.clientSecret.secretName.
resource "kubernetes_secret" "sso_client_secret" {
  count = (local.auth_sources.sso == "google" && var.google_client_secret != "") ? 1 : 0

  metadata {
    name      = "platforma-sso-client-secret"
    namespace = kubernetes_namespace.platforma.metadata[0].name
  }

  data = {
    "client-secret" = var.google_client_secret
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

        auth = {
          showUserList = var.show_user_list
          providers    = local.auth_providers
        }

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
          # gpuCpu/gpuRam/gpuMemory are added only when GPU is enabled — the
          # chart requires them if kueue.pools.gpu.enabled, and they mirror the
          # largest GPU node provisioned (see effective_gpu_max_job_* in
          # presets.tf; install.sh derives them from the discovered pools).
          maxJobResources = merge({
            cpu    = local.effective_kueue_max_job_cpu
            memory = local.effective_kueue_max_job_memory
            }, var.enable_gpu ? {
            gpuCpu    = local.effective_gpu_max_job_cpu
            gpuRam    = local.effective_gpu_max_job_ram
            gpuMemory = local.effective_gpu_max_job_memory
          } : {})
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
              enabled = var.enable_gpu
              tolerations = [{
                key      = "nvidia.com/gpu"
                operator = "Equal"
                value    = "present"
                effect   = "NoSchedule"
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
              # GPU ClusterQueue admission cap. Sized from gpu_capacity in
              # presets.tf so the GCE NVIDIA_L4_GPUS regional quota is the
              # binding constraint (not Kueue admission). The "gpu" field
              # name maps to "nvidia.com/gpu" inside the chart template
              # (helm/charts/platforma/templates/kueue-clusterqueues.yaml).
              gpu = {
                cpu    = local.effective_kueue_gpu_queue_cpu
                memory = local.effective_kueue_gpu_queue_memory
                gpu    = local.effective_kueue_gpu_queue_count
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
          # The backend runs on its own dedicated node pool (role=platforma,
          # tainted dedicated=platforma), split out from the system pool so its
          # memory can grow into a whole node without contending with the cluster
          # services (MILAB-6566). The default platforma_pool_machine_type is
          # n2d-standard-16 (~58 GiB allocatable), which realizes the full 32 GiB
          # limit below with headroom.
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
          # No zone constraint is needed here: the platforma node pool is defined
          # in terraform-infra/gke.tf with location = local.zone, and the cluster
          # is zonal (main.tf: zone = "${region}-${zone_suffix}"). Every node pool
          # — and the zonal database PD — lives in that single zone, so there is no
          # cross-AZ attach risk to pin against (unlike AWS EKS, whose pools can
          # span AZs). role=platforma + the taint toleration are all that's needed.
          nodeSelector = {
            role = "platforma"
          }
          tolerations = [{
            key    = "dedicated"
            value  = "platforma"
            effect = "NoSchedule"
          }]
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

          # Pull block software images through the GAR quay.io mirror (the infra
          # module's pull-through cache) instead of from quay.io directly. The
          # --google-artifact-registry flag lets Google Batch job VMs docker-login
          # to GAR with an SA token; it is a no-op on the GKE/Kueue path (kubelet
          # pulls with the node SA) and harmless when Batch is disabled.
          extraArgs = concat(
            [
              "--default-docker-registry=${local.default_docker_registry}",
              "--google-artifact-registry=${local.artifact_registry_login_host}",
            ],
            var.additional_extra_args,
          )
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
    kubernetes_secret.sso_client_secret,
    kubernetes_secret.master_secret,
  ]

  lifecycle {
    precondition {
      condition     = var.auth_method == "" || !local.auth_combinable_variables_set
      error_message = <<-EOT
        auth_method is deprecated and cannot be combined with the login-source variables.
        auth_method = "${var.auth_method}" is set beside at least one of sso_provider,
        enable_local_users, sso_admin_users, ldap_admin_users or local_admin_users.
        Leave auth_method unset and express the same configuration with the variables that combine:
          auth_method = "google" / "entra" / "oidc"  ->  sso_provider = that value
          auth_method = "ldap"                       ->  ldap_server already switches the source on
          auth_method = "htpasswd" + htpasswd_content ->  enable_local_users = true
      EOT
    }
    precondition {
      condition     = length([for arg in var.additional_extra_args : arg if startswith(arg, "--admin-user")]) == 0
      error_message = <<-EOT
        additional_extra_args still carries a --admin-user flag, which this module no longer honours.
        Under auth.providers the backend grants the admin role per login source, so a global
        --admin-user reaches nobody and no layer warns you.
        Move each pattern to the variable of the source that authenticates it:
          the SSO source   ->  sso_admin_users
          the corp LDAP    ->  ldap_admin_users
          the local users  ->  local_admin_users
        Each takes semicolon-separated full-match regexps, e.g. "alice@example.com;^ops-.*$".
      EOT
    }
    precondition {
      condition     = !var.enable_local_users || nonsensitive(var.htpasswd_content != "")
      error_message = "enable_local_users is true but htpasswd_content is empty. The 'local' source advertises that file, so set htpasswd_content, or leave enable_local_users false and use the admin login."
    }
    precondition {
      condition     = nonsensitive(var.htpasswd_content == "") || var.enable_local_users || var.auth_method != ""
      error_message = <<-EOT
        htpasswd_content is set but no login source advertises it. auth_method is empty and
        enable_local_users is false, so those users would have no login at all after this apply.
        Add:
          enable_local_users = true
        Earlier versions advertised the file whenever auth_method held its old "htpasswd" default.
        That default is gone, so the source is now named rather than implied.
      EOT
    }
    precondition {
      condition = alltrue([
        var.sso_admin_users == "" || local.auth_sources.sso != "",
        var.ldap_admin_users == "" || local.auth_sources.ldap,
        var.local_admin_users == "" || local.auth_sources.local,
      ])
      error_message = <<-EOT
        An admin-user variable names patterns for a login source this apply does not advertise.
        The patterns are computed and dropped, so they grant the admin role to nobody and no
        layer warns you.
        Advertise the source, or clear the patterns:
          sso_admin_users    ->  sso_provider = "google" / "entra" / "oidc"
          ldap_admin_users   ->  ldap_server = the directory URL
          local_admin_users  ->  enable_local_users = true
      EOT
    }
    precondition {
      condition     = local.auth_sources.sso != "google" || var.google_client_id != ""
      error_message = "google_client_id is required when the SSO source is 'google'."
    }
    precondition {
      condition     = local.auth_sources.sso != "google" || var.google_client_secret != ""
      error_message = "google_client_secret is required when the SSO source is 'google'."
    }
    precondition {
      condition     = local.auth_sources.sso != "entra" || (var.entra_tenant_id != "" && var.entra_client_id != "")
      error_message = "entra_tenant_id and entra_client_id are both required when the SSO source is 'entra'."
    }
    precondition {
      condition     = local.auth_sources.sso != "oidc" || (var.oidc_issuer != "" && var.oidc_client_id != "")
      error_message = "oidc_issuer and oidc_client_id are both required when the SSO source is 'oidc'."
    }
  }
}
