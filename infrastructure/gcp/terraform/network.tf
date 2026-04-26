resource "google_compute_network" "vpc" {
  name                    = var.vpc_name
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  depends_on = [google_project_service.enabled]
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.vpc_name}-nodes"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_nodes_cidr

  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.subnet_pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.subnet_services_cidr
  }
}

resource "google_compute_global_address" "private_service_access" {
  name          = "${var.vpc_name}-psa"
  project       = var.project_id
  network       = google_compute_network.vpc.id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20

  depends_on = [google_project_service.enabled]
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.vpc.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_access.name]

  depends_on = [google_project_service.enabled]
}

# -----------------------------------------------------------------------------
# Cloud Router + Cloud NAT — egress for private GKE nodes.
#
# All worker nodes are private (no external IPs — see gke.tf
# private_cluster_config). They need internet egress to:
#   - pull container images (quay.io, ghcr.io, gcr.io)
#   - reach the cross-cloud demo data library (S3)
#   - reach external LDAP servers / licensing API
#   - reach non-Google internet for whatever the workflow does
#
# Cloud NAT auto-allocates 1-2 public IPs per region and translates outbound
# traffic from internal node IPs through them. With dynamic port allocation,
# a single NAT IP supports thousands of concurrent connections.
#
# Google API traffic (storage.googleapis.com, iam, logging, monitoring)
# bypasses NAT via Private Google Access — see private_ip_google_access on
# the nodes subnet above. PGA is faster and avoids NAT processing fees on
# the high-volume GCS traffic that bioinformatics workloads generate.
#
# IN_USE_ADDRESSES quota usage with this design: 1 static IP for the GKE
# Gateway + ~1-2 NAT IPs = 2-3 per region. Default GCP quota is 8, so no
# auto-bump needed in the common case (still requested at 16 in presets.tf
# for headroom).
# -----------------------------------------------------------------------------

resource "google_compute_router" "primary" {
  name    = "${var.cluster_name}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id

  depends_on = [google_project_service.enabled]
}

resource "google_compute_router_nat" "primary" {
  name    = "${var.cluster_name}-nat"
  project = var.project_id
  region  = var.region
  router  = google_compute_router.primary.name

  # AUTO_ONLY: Google manages NAT IPs. We don't need static IPs (no
  # downstream service whitelists outbound traffic from these nodes).
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  # Dynamic port allocation lets the NAT scale from min_ports per VM up to
  # 2x dynamically — handles bursty egress (e.g. parallel image pulls when
  # the cluster scales up) without preallocating ports per VM.
  enable_dynamic_port_allocation = true
  min_ports_per_vm               = 64

  # Endpoint-independent mapping reuses the same {NAT-IP, port} for a given
  # VM regardless of destination. Required for some peer-to-peer protocols
  # but burns more ports — disable since we don't need it.
  enable_endpoint_independent_mapping = false

  log_config {
    enable = false
    filter = "ERRORS_ONLY"
  }
}
