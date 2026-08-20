# =============================================================================
# Platforma release — secrets, data-source wiring, and the Helm install
# =============================================================================
# Mirrors the CF HelmDeployer's Platforma step (cloudformation-eks-1-35.yaml
# lines 2980-3326): create the license + auth + data-library secrets, assemble
# the values document, and install the chart. Everything here is gated on
# deploy_platforma so the module can stand up just the controllers.
# =============================================================================

locals {
  # Pre-existing secret wins; otherwise the one we create below. Both the app
  # and the job pods read the license from this name (chart: license.secretName
  # and jobs.secretName, each defaulting to "platforma-license").
  license_secret_effective = var.license_secret_name != "" ? var.license_secret_name : "platforma-license"

  htpasswd_secret_name = "platforma-htpasswd"

  create_license          = var.deploy_platforma && var.license_secret_name == ""
  htpasswd_selected       = var.deploy_platforma && var.auth_method == "htpasswd"
  htpasswd_auto_generated = local.htpasswd_selected && var.htpasswd_content == ""
  htpasswd_user_provided  = local.htpasswd_selected && var.htpasswd_content != ""

  # StartTLS upgrades a plain ldap:// connection; it is incompatible with
  # ldaps:// (already encrypted). Force it off for ldaps:// to match CF.
  ldap_effective_start_tls = startswith(lower(var.ldap_server), "ldaps://") ? false : var.ldap_start_tls

  # Libraries carrying explicit creds get a K8s Secret (keyed by name, which the
  # variable validates as DNS-safe). Credential-less libraries use the platforma
  # IRSA role (infra granted it read on these buckets) — no secret needed.
  libs_with_creds = var.deploy_platforma ? {
    for lib in var.data_libraries : lib.name => lib if lib.access_key != ""
  } : {}

  master_secret_value = data.aws_ssm_parameter.master_secret.value
}

# -----------------------------------------------------------------------------
# License secret (key MI_LICENSE). Skipped when license_secret_name points at a
# secret the operator manages out of band.
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "license" {
  count = local.create_license ? 1 : 0

  metadata {
    name      = "platforma-license"
    namespace = var.platforma_namespace
  }

  data = {
    MI_LICENSE = var.license_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.platforma]
}

# -----------------------------------------------------------------------------
# htpasswd auth (when auth_method = htpasswd).
#
# No htpasswd_content supplied → auto-generate a single 'platforma' user: a
# random password is stored in SSM (SecureString) so an operator can retrieve
# it, and the Secret holds its bcrypt hash. The chart consumes bcrypt (its
# `htpasswd` helper and docs both use `htpasswd -nB`), so Terraform's built-in
# bcrypt() is the right hasher and needs no extra provider.
#
# bcrypt() salts randomly, so the hash differs every plan; ignore_changes on
# data keeps the first hash stable (it still validates the same password)
# instead of churning the Secret on every apply.
# -----------------------------------------------------------------------------
resource "random_password" "users" {
  count = local.htpasswd_auto_generated ? 1 : 0

  length  = 20
  special = false
}

resource "aws_ssm_parameter" "users_password" {
  count = local.htpasswd_auto_generated ? 1 : 0

  name        = "/${var.cluster_name}/platforma/users-password"
  description = "Auto-generated password for the Platforma 'platforma' htpasswd user."
  type        = "SecureString"
  value       = random_password.users[0].result
}

resource "kubernetes_secret" "htpasswd_generated" {
  count = local.htpasswd_auto_generated ? 1 : 0

  metadata {
    name      = local.htpasswd_secret_name
    namespace = var.platforma_namespace
  }

  data = {
    htpasswd = "platforma:${bcrypt(random_password.users[0].result)}"
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data]
  }

  depends_on = [kubernetes_namespace.platforma]
}

# -----------------------------------------------------------------------------
# Master secret — root key for DB encryption + session/resource signing
# (charts/platforma/values.yaml:58-78).
#
# Externally owned: the SSM SecureString parameter is pre-staged by the
# operator (or by the CloudFormation deployer for CFN-based installs)
# before apply, and its name is passed via var.master_secret_ssm_parameter_name.
# Terraform reads the latest value here and materializes the Kubernetes
# Secret consumed by the chart; it does NOT create, own, or rotate the
# SSM parameter. terraform destroy leaves the parameter intact.
#
# Rotation is performed out-of-band:
#   aws ssm put-parameter --type SecureString --overwrite \
#     --name "$PARAM_NAME" --value "$(openssl rand -base64 32)"
# Re-applies pick up the latest version on the next plan.
# -----------------------------------------------------------------------------
data "aws_ssm_parameter" "master_secret" {
  name            = var.master_secret_ssm_parameter_name
  with_decryption = true
}

resource "kubernetes_secret" "master_secret" {
  metadata {
    name      = "platforma-master-secret"
    namespace = var.platforma_namespace
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
  # We deliberately do NOT call base64decode() here — Terraform
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
        The current value (from SSM parameter ${var.master_secret_ssm_parameter_name}) is too short or not valid base64.
        Terraform does not own this parameter — overwrite it with a fresh value:
          aws ssm put-parameter --type SecureString --overwrite \
            --name ${var.master_secret_ssm_parameter_name} \
            --value "$(openssl rand -base64 32)"
        then re-run terraform apply.
      EOT
    }
  }

  depends_on = [kubernetes_namespace.platforma]
}

resource "kubernetes_secret" "htpasswd_provided" {
  count = local.htpasswd_user_provided ? 1 : 0

  metadata {
    name      = local.htpasswd_secret_name
    namespace = var.platforma_namespace
  }

  data = {
    htpasswd = var.htpasswd_content
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.platforma]
}

# -----------------------------------------------------------------------------
# Data-library credential secrets (only for libraries with an access key).
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "library_creds" {
  for_each = local.libs_with_creds

  metadata {
    name      = "platforma-library-${each.key}-creds"
    namespace = var.platforma_namespace
  }

  data = {
    "access-key" = each.value.access_key
    "secret-key" = each.value.secret_key
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.platforma]
}

# -----------------------------------------------------------------------------
# MiLaboratories demo data library. The credentials are MiLaboratories-owned,
# read-only, and cross-account — they are shipped with the product (verbatim
# from the CF template), NOT derived from this account's IRSA roles.
# -----------------------------------------------------------------------------
resource "kubernetes_secret" "demo_library" {
  count = var.deploy_platforma && var.enable_demo_data_library ? 1 : 0

  metadata {
    name      = "platforma-library-demo-creds"
    namespace = var.platforma_namespace
  }

  data = {
    "access-key" = "AKIAXOL6R5EBCOHXV7PC"
    "secret-key" = "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"
  }

  type = "Opaque"

  depends_on = [kubernetes_namespace.platforma]
}

# -----------------------------------------------------------------------------
# Values assembly. Built as merged HCL maps and serialized with yamlencode,
# mirroring the CF heredoc (lines 3167-3313). Top-level keys across the
# fragments are disjoint, so a shallow merge is correct.
# -----------------------------------------------------------------------------
locals {
  data_sources_from_libs = [
    for lib in var.data_libraries : {
      name = lib.name
      type = "s3"
      s3 = merge(
        {
          bucket = lib.bucket
          region = lib.region != "" ? lib.region : var.region
        },
        lib.prefix != "" ? { prefix = lib.prefix } : {},
        lib.endpoint != "" ? { endpoint = lib.endpoint } : {},
        lib.external_endpoint != "" ? { externalEndpoint = lib.external_endpoint } : {},
        lib.access_key != "" ? { secretRef = { name = "platforma-library-${lib.name}-creds" } } : {},
      )
    }
  ]

  data_source_demo = {
    name = "milabs-demo-data"
    type = "s3"
    s3 = {
      bucket = "milab-euce1-prod-eks-s3-farm-library"
      region = "eu-central-1"
      secretRef = {
        name = "platforma-library-demo-creds"
      }
    }
  }

  data_sources = concat(
    local.data_sources_from_libs,
    var.enable_demo_data_library ? [local.data_source_demo] : [],
  )

  base_values = {
    environment = "aws"
    storage = {
      database = {
        size         = "50Gi"
        storageClass = "gp3"
      }
      workspace = {
        efs = {
          enabled      = true
          fileSystemId = local.efs_file_system_id
        }
      }
      main = {
        type = "s3"
        s3 = {
          bucket = var.s3_bucket_name
          region = var.region
        }
      }
    }
    serviceAccount = {
      create = true
      annotations = {
        "eks.amazonaws.com/role-arn" = local.platforma_role_arn
      }
    }
    jobServiceAccount = {
      create = true
      annotations = {
        "eks.amazonaws.com/role-arn" = local.platforma_jobs_role_arn
      }
    }
    kueue = {
      maxJobResources = merge(
        {
          cpu    = local.max_job_cpu
          memory = "${local.max_job_memory_gi}Gi"
        },
        var.enable_gpu ? {
          gpuMemory = "${local.max_job_gpu_memory_gi}Gi"
          gpuCpu    = local.max_job_gpu_cpu
          gpuRam    = "${local.max_job_gpu_ram_gi}Gi"
        } : {},
      )
      mode = "dedicated"
      pools = {
        ui = {
          nodeSelector = { "node.kubernetes.io/pool" = "ui" }
          tolerations  = [{ key = "dedicated", value = "ui", effect = "NoSchedule" }]
        }
        batch = {
          nodeSelector = { "node.kubernetes.io/pool" = "batch" }
          tolerations  = [{ key = "dedicated", value = "batch", effect = "NoSchedule" }]
        }
        gpu = {
          enabled     = var.enable_gpu
          tolerations = [{ key = "nvidia.com/gpu", value = "present", effect = "NoSchedule" }]
        }
      }
      provisioningRequest = {
        enabled = true
      }
      dedicated = {
        resources = {
          ui = {
            cpu    = local.preset.ui_cpu
            memory = "${local.preset.ui_memory_gi}Gi"
          }
          batch = {
            cpu    = local.preset.batch_cpu
            memory = "${local.preset.batch_memory_gi}Gi"
          }
          # cpu/memory are DERIVED by the chart from gpu × maxJobResources.gpuCpu/gpuRam;
          # only the GPU-job concurrency count is set here.
          gpu = {
            gpu = local.gpu_queue_gpu
          }
        }
      }
    }
    app = {
      resources = {
        requests = { cpu = 4, memory = "16Gi" }
        limits   = { cpu = 8, memory = "32Gi" }
      }
      nodeSelector = { "node.kubernetes.io/pool" = "system" }
      extraArgs = concat(
        ["--default-docker-registry=${local.ecr_registry}"],
        var.additional_extra_args,
      )
    }
    dataSources = local.data_sources
  }

  license_values = {
    license = { secretName = local.license_secret_effective }
    jobs    = { secretName = local.license_secret_effective }
  }

  master_secret_values = {
    masterSecret = {
      secretName = kubernetes_secret.master_secret.metadata[0].name
      secretKey  = "master-secret"
    }
  }

  # When enabled, the ALB-specific keys are added on top of `enabled`. Built via
  # merge over a 0-or-1-element list (rather than a ternary that returns two
  # differently-shaped objects, which OpenTofu rejects as a type mismatch).
  ingress_alb_block = var.ingress_enabled ? [{
    className = "alb"
    host      = var.domain_name
    tls       = { enabled = true }
    annotations = {
      "alb.ingress.kubernetes.io/scheme"                   = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"              = "ip"
      "alb.ingress.kubernetes.io/listen-ports"             = "[{\"HTTPS\":443}]"
      "alb.ingress.kubernetes.io/certificate-arn"          = local.acm_certificate_arn
      "alb.ingress.kubernetes.io/backend-protocol-version" = "GRPC"
      "alb.ingress.kubernetes.io/healthcheck-path"         = "/grpc.health.v1.Health/Check"
      "alb.ingress.kubernetes.io/success-codes"            = "0"
    }
  }] : []

  ingress_values = {
    ingress = merge({ enabled = var.ingress_enabled }, local.ingress_alb_block...)
  }

  auth_values = var.auth_method == "htpasswd" ? {
    auth = {
      htpasswd = { secretName = local.htpasswd_secret_name }
    }
    } : {
    auth = {
      ldap = merge(
        {
          server   = var.ldap_server
          startTLS = local.ldap_effective_start_tls
        },
        var.ldap_bind_dn != "" ? { bindDN = var.ldap_bind_dn } : {},
        var.ldap_search_user != "" ? {
          searchUser     = var.ldap_search_user
          searchPassword = var.ldap_search_password
        } : {},
        length(var.ldap_search_rules) > 0 ? { searchRules = var.ldap_search_rules } : {},
      )
    }
  }

  # Split on the LAST colon so a registry that carries a port
  # (host:5000/repo:tag) keeps the port in the repository, not the tag.
  image_parts = var.platforma_image != "" ? regex("^(?P<repository>.+):(?P<tag>[^:/]+)$", var.platforma_image) : null
  image_values = var.platforma_image != "" ? {
    image = {
      repository = local.image_parts.repository
      tag        = local.image_parts.tag
    }
  } : {}

  platforma_values = merge(
    local.base_values,
    local.license_values,
    local.master_secret_values,
    local.ingress_values,
    local.auth_values,
    local.image_values,
  )
}

# -----------------------------------------------------------------------------
# Platforma Helm release. Chart pulled from the OCI registry (version-pinned),
# or from a local path when chart_local_path is set. --atomic so a failed
# install rolls back instead of leaving half a release behind.
# -----------------------------------------------------------------------------
resource "helm_release" "platforma" {
  count = var.deploy_platforma ? 1 : 0

  name      = var.helm_release_name
  chart     = var.chart_local_path != "" ? var.chart_local_path : var.chart_repository
  version   = var.chart_local_path != "" ? null : var.chart_version
  namespace = var.platforma_namespace

  atomic  = true
  timeout = 900

  values = [yamlencode(local.platforma_values)]

  lifecycle {
    precondition {
      condition     = var.license_key != "" || var.license_secret_name != ""
      error_message = "deploy_platforma = true requires a license: set license_key, or point license_secret_name at a pre-existing secret holding MI_LICENSE."
    }
    precondition {
      condition     = var.auth_method != "ldap" || var.ldap_server != ""
      error_message = "auth_method = ldap requires ldap_server to be set."
    }
  }

  depends_on = [
    kubernetes_namespace.platforma,
    helm_release.kueue,
    kubectl_manifest.appwrapper,
    helm_release.cluster_autoscaler,
    helm_release.external_dns,
    helm_release.alb_controller,
    kubernetes_secret.license,
    kubernetes_secret.htpasswd_generated,
    kubernetes_secret.htpasswd_provided,
    kubernetes_secret.library_creds,
    kubernetes_secret.demo_library,
    kubernetes_secret.master_secret,
    aws_ssm_parameter.users_password,
  ]
}
