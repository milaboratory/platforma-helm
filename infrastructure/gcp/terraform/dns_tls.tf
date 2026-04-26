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
}

# -- DNS authorization for Certificate Manager (proves we control the domain)
resource "google_certificate_manager_dns_authorization" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name        = "${var.cluster_name}-dns-auth"
  project     = var.project_id
  location    = "global"
  domain      = var.domain_name
  description = "DNS authorization for Platforma TLS cert"
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

  depends_on = [google_dns_record_set.cert_validation]
}

# -- Cert map (Gateway references the map, not individual certs)
resource "google_certificate_manager_certificate_map" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name        = "${var.cluster_name}-cert-map"
  project     = var.project_id
  description = "Platforma cert map for Gateway"
}

resource "google_certificate_manager_certificate_map_entry" "platforma" {
  count = var.ingress_enabled ? 1 : 0

  name         = "${var.cluster_name}-cert-entry"
  project      = var.project_id
  map          = google_certificate_manager_certificate_map.platforma[0].name
  certificates = [google_certificate_manager_certificate.platforma[0].id]
  hostname     = var.domain_name
}

# =============================================================================
# Gateway + HTTPRoute (Kubernetes Gateway API, GKE-managed)
# =============================================================================
# Platforma server speaks gRPC only on port 6345. GKE Gateway needs to forward
# to the backend via HTTP/2 (h2c) AND health-check via gRPC. We provision:
#   - A parallel Service "platforma-grpc" with appProtocol=kubernetes.io/h2c
#     so the Gateway controller knows to use HTTP/2 cleartext to the backend
#     (the chart's own Service has no appProtocol → controller defaults to
#     HTTP/1.1 and the gRPC backend rejects, marking it unhealthy)
#   - A HealthCheckPolicy hitting /grpc.health.v1.Health/Check (the same path
#     AWS ALB uses; mirrors infrastructure/aws/cloudformation-eks-1-35.yaml)
#   - Gateway with TLS terminated at L7 via Certificate Manager certmap
#   - HTTPRoute pointing at platforma-grpc:6345
# =============================================================================

resource "kubernetes_service" "platforma_grpc" {
  count = var.ingress_enabled ? 1 : 0

  metadata {
    name      = "platforma-grpc"
    namespace = var.platforma_namespace
    labels = {
      "app.kubernetes.io/name"      = "platforma"
      "app.kubernetes.io/instance"  = var.helm_release_name
      "app.kubernetes.io/component" = "ingress-backend"
    }
  }

  spec {
    type = "ClusterIP"
    selector = {
      "app.kubernetes.io/name"     = "platforma"
      "app.kubernetes.io/instance" = var.helm_release_name
    }
    port {
      name         = "grpc"
      port         = 6345
      target_port  = "grpc"
      protocol     = "TCP"
      app_protocol = "kubernetes.io/h2c"
    }
  }

  depends_on = [helm_release.platforma]
}

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
        name  = "platforma-grpc"
      }
    }
  })

  depends_on = [kubernetes_service.platforma_grpc]
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
    google_certificate_manager_certificate_map_entry.platforma,
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
          name = "platforma-grpc"
          port = 6345
        }]
      }]
    }
  })

  depends_on = [
    kubectl_manifest.platforma_gateway,
    kubernetes_service.platforma_grpc,
    kubectl_manifest.platforma_healthcheck,
  ]
}
