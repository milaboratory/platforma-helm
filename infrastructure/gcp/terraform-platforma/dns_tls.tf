# =============================================================================
# Ingress — Kubernetes Gateway API resources
# =============================================================================
# GCP-side resources (static IP, Cert Manager certmap, DNS A record + DNS
# authorization) live in the infra module. The K8s-side Gateway/HTTPRoute/
# HealthCheckPolicy are created here so the chart resources (Service the
# HTTPRoute targets, namespace they live in) are managed by the same plan
# that creates them.
#
# Names referenced from the infra module are derived from var.cluster_name
# in data.tf locals — keeps both modules synchronised without cross-module
# data passing for these string-typed references.
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
# the infra module destroys the Certificate Manager certmap.
#
# Ordering problem this solves: when terraform destroys
# kubectl_manifest.platforma_gateway, the Kubernetes Gateway is removed in
# ~1s, but the gke-l7-global-external-managed controller takes 30-90s to
# clean up the GCP-side urlMap / targetHttpsProxy / forwardingRule /
# backendService / NEGs that the Gateway implicitly created. The
# targetHttpsProxy holds a reference to the certmap (managed by the infra
# module), so the infra-module destroy that follows would fail with
# "is already being used by ... targetHttpsProxies/...".
#
# null_resource sits between certmap_name (a local string, doesn't need
# Terraform ordering) and the Gateway (created later, destroyed earlier).
# On destroy:
#   1) Gateway is removed (terraform → K8s API).
#   2) This null_resource's destroy provisioner polls for the gkegw1-*
#      targetHttpsProxies to disappear (controller-driven cleanup).
#   3) teardown.sh proceeds to destroy the infra module, which removes the
#      certmap cleanly.
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
          # GFE child resources (THP/UrlMap/BES) gone — at this point the
          # certmap is no longer referenced by any active LB component.
          # The previous "describe certmap" probe here was always-true
          # noise: the certmap lives in the infra module and isn't
          # destroyed until the second IM deployment runs, so it would
          # describe successfully every iteration regardless of dereference
          # status. Drop it and rely on a fixed grace for Cert Manager
          # API consistency (~30s of post-LB-cleanup quiescence is what
          # the targetHttpsProxy → certmap reverse reference actually
          # needs in practice).
          echo "GFE child resources cleaned up. 30s grace for Cert Manager API consistency..."
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
        "networking.gke.io/certmap" = local.certmap_name
      }
    }
    spec = {
      gatewayClassName = "gke-l7-global-external-managed"
      addresses = [{
        type  = "NamedAddress"
        value = local.ingress_ip_name
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
