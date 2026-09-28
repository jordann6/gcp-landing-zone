# Core network hub, 10.0.0.0/16.
#
# On GCP the hub is not an inspection point (firewall.tf explains why), so it
# holds the two things that genuinely are shared across environments:
#
#   DNS         an inbound forwarding policy, so an on-prem resolver can query
#               Cloud DNS, and a private lz.internal. zone visible from every
#               environment VPC. Name resolution is shared; routing is not.
#   Hybrid      an HA VPN gateway and Cloud Router with no tunnels. The gateway
#               bills nothing until a tunnel exists, so the on-prem attachment
#               point is reserved at zero cost. Production replaces it with
#               Dedicated or Partner Interconnect.
#
# Environment VPCs are deliberately not peered to the hub. Peering is
# non-transitive on GCP, but it would still put every environment one hop from
# the hub; with no peering, dev and prod have no route to each other at all.

locals {
  hub_project = local.gov.hub_project_id
  hub         = local.hub_project == null ? {} : { hub = local.hub_project }
}

resource "google_compute_network" "hub" {
  # checkov:skip=CKV2_GCP_18: governed by the org hierarchical firewall policy;
  # the hub runs no workloads of its own.
  for_each = local.hub

  project                         = each.value
  name                            = "vpc-hub"
  auto_create_subnetworks         = false
  routing_mode                    = "GLOBAL"
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "hub" {
  for_each = local.hub

  project                  = each.value
  name                     = "snet-hub-${var.region}"
  network                  = google_compute_network.hub[each.key].id
  region                   = var.region
  ip_cidr_range            = "10.0.0.0/24"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

resource "google_dns_policy" "hub_inbound" {
  for_each = local.hub

  project                   = each.value
  name                      = "hub-inbound-forwarding"
  description               = "Lets an on-prem resolver forward queries into Cloud DNS through the hybrid link."
  enable_inbound_forwarding = true
  enable_logging            = true

  networks {
    network_url = google_compute_network.hub[each.key].id
  }
}

resource "google_dns_managed_zone" "internal" {
  for_each = local.hub

  project     = each.value
  name        = "lz-internal"
  dns_name    = "lz.internal."
  description = "Shared private zone, resolvable from the hub and every environment VPC."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.hub[each.key].id
    }

    dynamic "networks" {
      for_each = google_compute_network.vpc
      content {
        network_url = networks.value.id
      }
    }
  }
}

resource "google_compute_router" "hybrid" {
  for_each = var.enable_hybrid_placeholder ? local.hub : {}

  project = each.value
  name    = "cr-hub-hybrid"
  region  = var.region
  network = google_compute_network.hub[each.key].id

  bgp {
    asn = 64514
  }
}

resource "google_compute_ha_vpn_gateway" "hybrid" {
  for_each = var.enable_hybrid_placeholder ? local.hub : {}

  project = each.value
  name    = "havpn-hub-onprem"
  region  = var.region
  network = google_compute_network.hub[each.key].id
}
