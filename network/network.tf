# VPCs and the address plan.
#
# Same plan as the AWS and Azure zones, because the three are isolated and can
# reuse it: hub 10.0/16, dev 10.1, test 10.2, prod 10.3, sandbox 10.4.
#
# Each environment /16 is split by tier, following the foundations blueprint's
# base + restricted Shared VPC pair:
#
#   10.N.0.0/17    restricted VPC (net-<env>-r host, inside the VPC-SC perimeter)
#     10.N.0.0/20    workload subnet, GKE nodes
#     10.N.16.0/20   private services access (Cloud SQL peering range)
#     10.N.32.0/19   GKE services (secondary)
#     10.N.64.0/18   GKE pods (secondary)
#   10.N.128.0/17  base VPC (net-<env> host)
#     10.N.128.0/20  workload subnet
#     10.N.144.0/28  reserved: GKE control plane range
#   10.N.255.253   PSC endpoint, base VPC     (all-apis bundle)
#   10.N.255.254   PSC endpoint, restricted   (vpc-sc bundle)
#
# The prod Kubernetes ranges (nodes 10.3.0.0/20, pods 10.3.64.0/18, services
# 10.3.32.0/19) are the ones in the design doc, identical to EKS and AKS.

locals {
  # Remote state drops null outputs, so the optional projects (hub, sandbox)
  # are absent rather than null when the vend set leaves them out. The
  # defaults put them back as null for the checks below.
  gov = merge(
    { hub_project_id = null, sandbox_project_id = null, image_project_id = null },
    data.terraform_remote_state.governance.outputs,
  )

  env_octet = { hub = 0, dev = 1, test = 2, prod = 3, sandbox = 4 }

  hosts = local.gov.host_projects

  # One VPC per host project, plus the sandbox's standalone VPC. Keyed the same
  # as the host map so every per-VPC resource below is a for_each over this.
  vpcs = merge(
    {
      for k, h in local.hosts : k => {
        project    = h.project_id
        env        = h.env
        restricted = h.restricted
        octet      = local.env_octet[h.env]
        subnet     = h.restricted ? "10.${local.env_octet[h.env]}.0.0/20" : "10.${local.env_octet[h.env]}.128.0/20"
        psc_ip     = h.restricted ? "10.${local.env_octet[h.env]}.255.254" : "10.${local.env_octet[h.env]}.255.253"
        own_range  = h.restricted ? "10.${local.env_octet[h.env]}.0.0/17" : "10.${local.env_octet[h.env]}.128.0/17"
      }
    },
    local.gov.sandbox_project_id == null ? {} : {
      sandbox = {
        project    = local.gov.sandbox_project_id
        env        = "sandbox"
        restricted = false
        octet      = 4
        subnet     = "10.4.0.0/20"
        psc_ip     = "10.4.255.253"
        own_range  = "10.4.0.0/16"
      }
    },
  )

  restricted_vpcs = { for k, v in local.vpcs : k => v if v.restricted }
}

resource "google_compute_network" "vpc" {
  # checkov:skip=CKV2_GCP_18: firewalling is by network firewall policy
  # (firewall.tf) and the org hierarchical policy, not classic VPC rules, which
  # this check does not recognize.
  for_each = local.vpcs

  project = each.value.project
  name    = each.value.restricted ? "vpc-${each.value.env}-restricted" : "vpc-${each.value.env}-base"

  # No auto subnets. Auto mode creates a subnet in every region with fixed
  # ranges, which forecloses IP planning and quietly extends the footprint into
  # regions the resource locations policy is trying to constrain.
  auto_create_subnetworks = false
  routing_mode            = "GLOBAL"

  # The default route to the internet gateway is deleted and re-added below only
  # where NAT needs it. Nothing reaches the internet by accident of defaults.
  delete_default_routes_on_create = true

  # Network firewall policies (firewall.tf) evaluate before classic VPC rules,
  # so the policy's default-deny egress cannot be overridden by a classic
  # allow-all that GKE or someone else adds later.
  network_firewall_policy_enforcement_order = "BEFORE_CLASSIC_FIREWALL"
}

resource "google_compute_subnetwork" "workload" {
  for_each = local.vpcs

  project       = each.value.project
  name          = "snet-${each.value.env}-${var.region}"
  network       = google_compute_network.vpc[each.key].id
  region        = var.region
  ip_cidr_range = each.value.subnet

  # Lets instances without external IPs reach Google APIs. Without it, the
  # vmExternalIpAccess deny would strand every VM, which is the usual reason
  # that policy gets rolled back rather than fixed.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  # GKE ranges only on the restricted tier, where the workload root builds the
  # cluster. Secondary ranges on the base tier would be unused address space.
  dynamic "secondary_ip_range" {
    for_each = each.value.restricted ? {
      pods     = "10.${each.value.octet}.64.0/18"
      services = "10.${each.value.octet}.32.0/19"
    } : {}
    content {
      range_name    = secondary_ip_range.key
      ip_cidr_range = secondary_ip_range.value
    }
  }
}

# Default route to the internet, only where Cloud NAT exists to use it. With no
# external IPs anywhere (org policy), this route is reachable only through NAT,
# and NAT is reachable only for what the FQDN allowlist permits.
resource "google_compute_route" "egress" {
  for_each = var.enable_nat ? local.vpcs : {}

  project          = each.value.project
  name             = "rt-${each.value.env}-${each.value.restricted ? "r" : "b"}-internet"
  network          = google_compute_network.vpc[each.key].name
  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

# ---- private services access (Cloud SQL) -------------------------------------

resource "google_compute_global_address" "psa" {
  for_each = local.restricted_vpcs

  project       = each.value.project
  name          = "psa-${each.value.env}"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  address       = "10.${each.value.octet}.16.0"
  prefix_length = 20
  network       = google_compute_network.vpc[each.key].id
}

resource "google_service_networking_connection" "psa" {
  for_each = local.restricted_vpcs

  network                 = google_compute_network.vpc[each.key].id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[each.key].name]

  # The peering outlives the Cloud SQL instances that used it by a few minutes
  # on destroy; ABANDON lets the network go without waiting on Google's side.
  deletion_policy = "ABANDON"
}

# ---- NAT ------------------------------------------------------------------------

resource "google_compute_router" "nat" {
  for_each = var.enable_nat ? local.vpcs : {}

  project = each.value.project
  name    = "cr-${each.value.env}-${var.region}"
  region  = var.region
  network = google_compute_network.vpc[each.key].id
}

# Cloud NAT bills per VM using it, capped per gateway, so an idle gateway costs
# close to nothing. Error-only logging: translation logs at full volume are the
# line item that surprises people, and the NGFW rule logs already show what was
# allowed out.
resource "google_compute_router_nat" "nat" {
  for_each = var.enable_nat ? local.vpcs : {}

  project                            = each.value.project
  name                               = "nat-${each.value.env}-${var.region}"
  router                             = google_compute_router.nat[each.key].name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
