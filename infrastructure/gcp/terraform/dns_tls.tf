# =============================================================================
# DNS + TLS + Ingress (HTTPS)
# =============================================================================
# Gated on var.ingress_enabled. When enabled, this provisions:
#   1. A reserved global static IP for the load balancer
#   2. A Cloud DNS A record pointing domain_name at that IP
#   3. A Certificate Manager DNS-authorization record (CNAME in the zone)
#   4. A Google-managed cert validated via DNS authorization
#   5. A Cert Map entry binding cert ↔ hostname
#   6. A GKE Gateway (gateway.networking.k8s.io) bound to the static IP and cert
#   7. An HTTPRoute forwarding HTTPS → in-cluster Platforma Service on 6345
#
# Cert issuance + DNS propagation usually completes in 5-15 min after apply.
#
# TODO (Phase 2 testing): gRPC backend protocol. The chart's Service does not
# currently set appProtocol on the gRPC port. GKE Gateway forwards as HTTP/1.1
# by default, which breaks gRPC. Resolution paths:
#   - Add `service.appProtocol = "kubernetes.io/h2c"` to chart values
#     (small chart PR), OR
#   - Set `cloud.google.com/app-protocols` annotation on the Service via the
#     chart's existing `app.serviceAnnotations` value (legacy Ingress shape).
# Decide once we test the Desktop App connection through the Gateway.
# =============================================================================

locals {
  dns_project = var.dns_zone_project != "" ? var.dns_zone_project : var.project_id
}

# -- Static external IP for the load balancer
resource "google_compute_global_address" "ingress" {
  count = var.ingress_enabled ? 1 : 0

  name    = "${var.cluster_name}-ingress"
  project = var.project_id

  lifecycle {
    precondition {
      condition     = var.domain_name != "" && var.dns_zone_name != ""
      error_message = "domain_name and dns_zone_name are required when ingress_enabled = true."
    }
  }

  depends_on = [google_project_service.enabled]
}

# -- A record: domain_name → static IP
resource "google_dns_record_set" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  project      = local.dns_project
  managed_zone = var.dns_zone_name
  name         = "${var.domain_name}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.ingress[0].address]

  depends_on = [google_project_service.enabled]
}

# -- DNS authorization for Certificate Manager (proves we control the domain)
resource "google_certificate_manager_dns_authorization" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name        = "${var.cluster_name}-dns-auth"
  project     = var.project_id
  location    = "global"
  domain      = var.domain_name
  description = "DNS authorization for Platforma TLS cert"

  depends_on = [google_project_service.enabled]
}

# -- CNAME validation record (created in the user's zone, points at GCP-managed target)
resource "google_dns_record_set" "cert_validation" {
  count = var.ingress_enabled ? 1 : 0

  project      = local.dns_project
  managed_zone = var.dns_zone_name
  name         = google_certificate_manager_dns_authorization.platforma[0].dns_resource_record[0].name
  type         = google_certificate_manager_dns_authorization.platforma[0].dns_resource_record[0].type
  ttl          = 300
  rrdatas      = [google_certificate_manager_dns_authorization.platforma[0].dns_resource_record[0].data]

  depends_on = [google_project_service.enabled]
}

# -- Google-managed certificate
resource "google_certificate_manager_certificate" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name        = "${var.cluster_name}-cert"
  project     = var.project_id
  location    = "global"
  description = "Platforma TLS certificate (managed by Certificate Manager)"

  managed {
    domains            = [var.domain_name]
    dns_authorizations = [google_certificate_manager_dns_authorization.platforma[0].id]
  }

  depends_on = [
    google_dns_record_set.cert_validation,
    google_project_service.enabled,
  ]
}

# -- Cert map (Gateway references the map, not individual certs)
resource "google_certificate_manager_certificate_map" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name        = "${var.cluster_name}-cert-map"
  project     = var.project_id
  description = "Platforma cert map for Gateway"

  depends_on = [google_project_service.enabled]
}

resource "google_certificate_manager_certificate_map_entry" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name         = "${var.cluster_name}-cert-entry"
  project      = var.project_id
  map          = google_certificate_manager_certificate_map.platforma[0].name
  certificates = [google_certificate_manager_certificate.platforma[0].id]
  hostname     = var.domain_name

  depends_on = [google_project_service.enabled]
}

# =============================================================================
# Gateway + HTTPRoute (Kubernetes Gateway API, GKE-managed)
# =============================================================================
# Platforma server speaks gRPC only on port 6345. GKE Gateway needs to forward
# to the backend via HTTP/2 (h2c) AND health-check via gRPC. We provision:
#   - A HealthCheckPolicy hitting /grpc.health.v1.Health/Check (mirrors the
#     AWS ALB health-check from infrastructure/aws/cloudformation-eks-1-35.yaml).
#   - Gateway with TLS terminated at L7 via Certificate Manager certmap.
#   - HTTPRoute pointing at the chart's main 'platforma' Service on port 6345.
#
# The h2c hint is set chart-side via app.serviceAppProtocols.grpc on the
# main Service (rendered from the helm values in app.tf). No parallel
# Service is needed.
# =============================================================================

resource "kubectl_manifest" "platforma_healthcheck" {
  count = var.ingress_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1"
    kind       = "HealthCheckPolicy"
    metadata = {
      name      = "platforma-grpc-healthcheck"
      namespace = var.platforma_namespace
    }
    spec = {
      default = {
        config = {
          type = "GRPC"
          grpcHealthCheck = {
            portSpecification = "USE_SERVING_PORT"
          }
        }
      }
      targetRef = {
        group = ""
        kind  = "Service"
        name  = var.helm_release_name
      }
    }
  })

  depends_on = [helm_release.platforma]
}

# Wait for the GKE Gateway controller to release GFE-side resources before
# terraform proceeds with destroying the Certificate Manager certmap.
#
# Ordering problem fixed here: when terraform destroys kubectl_manifest.
# platforma_gateway, the Kubernetes Gateway resource is removed in ~1s, but
# the gke-l7-global-external-managed controller takes 30-90s to clean up
# the GCP-side urlMap / targetHttpsProxy / forwardingRule / backendService
# / NEGs that the Gateway implicitly created. The targetHttpsProxy holds
# a reference to the certmap (terraform-tracked), so destroying the certmap
# next fails with "is already being used by ... targetHttpsProxies/...".
#
# null_resource is wedged between the certmap_entry (created earlier, so
# destroyed later) and the Gateway (created later, destroyed earlier). On
# destroy:
#   1) Gateway is removed (terraform → K8s API).
#   2) This null_resource's destroy provisioner runs and polls for the
#      gkegw1-* targetHttpsProxies to disappear (controller-driven cleanup).
#   3) Certmap_entry / certmap / cert / dns_auth destroy cleanly.
resource "null_resource" "wait_gateway_gfe_cleanup" {
  count = var.ingress_enabled ? 1 : 0

  triggers = {
    project      = var.project_id
    namespace    = var.platforma_namespace
    gateway_name = "platforma"
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      ns="${self.triggers.namespace}"
      gw="${self.triggers.gateway_name}"
      project="${self.triggers.project}"
      cluster_name="${self.triggers.cluster_name}"
      certmap_name="$${cluster_name}-cert-map"
      # Match all GFE child resources the controller creates per Gateway:
      # targetHttpsProxies, urlMaps, backendServices, forwardingRules, healthChecks.
      # Pattern: gkegw1-<hash>-<namespace>-<gateway-name>-...
      filter="name~^gkegw1-.*-$${ns}-$${gw}-"
      echo "Waiting for GKE Gateway controller to clean up GFE resources for $${ns}/$${gw}..."

      check_count() {
        local n=0
        local thp ums bes
        thp=$(gcloud compute target-https-proxies list --project="$${project}" --filter="$${filter}" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')
        ums=$(gcloud compute url-maps              list --project="$${project}" --filter="$${filter}" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')
        bes=$(gcloud compute backend-services      list --project="$${project}" --filter="$${filter}" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')
        n=$((thp + ums + bes))
        echo "$${n} (THP=$${thp} URLMap=$${ums} BES=$${bes})"
      }

      for i in $(seq 1 90); do
        result=$(check_count)
        count="$${result%% *}"
        if [ "$${count}" = "0" ]; then
          echo "GFE child resources cleaned up. Verifying certmap is dereferenced..."
          # Cert Manager API has its own reconciliation lag — even after the THP
          # is gone from compute API, the certmap may still report being in use
          # for several seconds. Poll the actual delete-readiness by attempting
          # a dry-run-style check (test with --quiet on a lookup, then a small
          # grace sleep). 30s grace covers the typical reconciliation window.
          for j in $(seq 1 6); do
            if gcloud certificate-manager maps describe "$${certmap_name}" \
                 --location=global --project="$${project}" \
                 --format="value(state)" >/dev/null 2>&1; then
              echo "  certmap still present (j=$${j}/6), sleeping 5s..."
              sleep 5
            else
              echo "certmap already removed."
              break
            fi
          done
          echo "Final 30s grace period for Cert Manager API consistency..."
          sleep 30
          exit 0
        fi
        echo "  GFE resources still present: $${result} (poll $${i}/90), sleeping 10s..."
        sleep 10
      done

      echo "ERROR: GKE Gateway controller did not clean up GFE resources within 15 min." >&2
      check_count >&2
      gcloud compute target-https-proxies list --project="$${project}" --filter="$${filter}" --format="value(name)" >&2
      exit 1
    EOT
  }

  depends_on = [
    google_certificate_manager_certificate_map_entry.platforma,
  ]
}

resource "kubectl_manifest" "platforma_gateway" {
  count = var.ingress_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "platforma"
      namespace = var.platforma_namespace
      annotations = {
        # GKE-specific: bind the Gateway to a Certificate Manager cert map.
        # The Gateway controller reads this annotation and provisions the
        # load balancer with the certs from the map.
        "networking.gke.io/certmap" = google_certificate_manager_certificate_map.platforma[0].name
      }
    }
    spec = {
      gatewayClassName = "gke-l7-global-external-managed"
      addresses = [{
        type  = "NamedAddress"
        value = google_compute_global_address.ingress[0].name
      }]
      listeners = [{
        name     = "https"
        protocol = "HTTPS"
        port     = 443
        # No tls block: cert is sourced from the certmap annotation on the
        # Gateway. The CEL rule "certificateRefs or options must be specified
        # when mode is Terminate" only applies if mode is set to Terminate;
        # omitting the tls block bypasses it.
      }]
    }
  })

  depends_on = [
    null_resource.wait_gateway_gfe_cleanup,
    helm_release.platforma,
  ]
}

resource "kubectl_manifest" "platforma_route" {
  count = var.ingress_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "platforma"
      namespace = var.platforma_namespace
    }
    spec = {
      parentRefs = [{ name = "platforma" }]
      hostnames  = [var.domain_name]
      rules = [{
        backendRefs = [{
          name = var.helm_release_name
          port = 6345
        }]
      }]
    }
  })

  depends_on = [
    kubectl_manifest.platforma_gateway,
    helm_release.platforma,
    kubectl_manifest.platforma_healthcheck,
  ]
}
