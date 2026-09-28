# Private Service Connect for Google APIs, and the DNS that points at it.
#
# Each VPC gets an internal endpoint for Google APIs, and private zones that
# resolve *.googleapis.com, *.pkg.dev (Artifact Registry) and *.gcr.io to it.
# Nothing in the workload tier reaches a Google API over a public address.
#
# The two tiers use different bundles, which is the point of having two:
#   base        all-apis   every Google API
#   restricted  vpc-sc     only APIs that VPC Service Controls supports, so a
#                          workload inside the perimeter cannot call an API the
#                          perimeter has no control over
#
# The default internet route is deleted on every VPC (network.tf), so without
# these endpoints a VM would have no path to Google APIs at all.

resource "google_compute_global_address" "psc" {
  for_each = var.enable_psc ? local.vpcs : {}

  project      = each.value.project
  name         = "psc-${each.value.env}-${each.value.restricted ? "r" : "b"}"
  purpose      = "PRIVATE_SERVICE_CONNECT"
  address_type = "INTERNAL"
  address      = each.value.psc_ip
  network      = google_compute_network.vpc[each.key].id
}

resource "google_compute_global_forwarding_rule" "psc" {
  for_each = var.enable_psc ? local.vpcs : {}

  project = each.value.project
  # PSC endpoint names for Google APIs: lowercase letters and digits, 1 to 20
  # characters, no hyphens.
  name                  = "psc${each.value.env}${each.value.restricted ? "r" : "b"}"
  target                = each.value.restricted ? "vpc-sc" : "all-apis"
  network               = google_compute_network.vpc[each.key].id
  ip_address            = google_compute_global_address.psc[each.key].id
  load_balancing_scheme = ""
}

locals {
  psc_zones = {
    googleapis = "googleapis.com."
    pkgdev     = "pkg.dev."
    gcrio      = "gcr.io."
  }

  vpc_zone_pairs = var.enable_psc ? {
    for pair in setproduct(keys(local.vpcs), keys(local.psc_zones)) :
    "${pair[0]}/${pair[1]}" => { vpc = pair[0], zone = pair[1] }
  } : {}
}

resource "google_dns_managed_zone" "psc" {
  for_each = local.vpc_zone_pairs

  project     = local.vpcs[each.value.vpc].project
  name        = "psc-${each.value.zone}-${replace(each.value.vpc, "_", "-")}"
  dns_name    = local.psc_zones[each.value.zone]
  description = "Resolves ${local.psc_zones[each.value.zone]} to the PSC endpoint in ${each.value.vpc}."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc[each.value.vpc].id
    }
  }
}

resource "google_dns_record_set" "psc_wildcard" {
  for_each = local.vpc_zone_pairs

  project      = local.vpcs[each.value.vpc].project
  managed_zone = google_dns_managed_zone.psc[each.key].name
  name         = "*.${local.psc_zones[each.value.zone]}"
  type         = "A"
  ttl          = 300
  rrdatas      = [local.vpcs[each.value.vpc].psc_ip]
}

# gcr.io and pkg.dev are also queried at the apex, not only as subdomains.
resource "google_dns_record_set" "psc_apex" {
  for_each = { for k, v in local.vpc_zone_pairs : k => v if v.zone != "googleapis" }

  project      = local.vpcs[each.value.vpc].project
  managed_zone = google_dns_managed_zone.psc[each.key].name
  name         = local.psc_zones[each.value.zone]
  type         = "A"
  ttl          = 300
  rrdatas      = [local.vpcs[each.value.vpc].psc_ip]
}
