# The bake network: private, with no path to the internet at all.
#
# The bake VM has no external IP (org policy) and this VPC has no NAT and no
# default route. Its only route leaves for private.googleapis.com
# (199.36.153.8/30), and private DNS points *.googleapis.com and *.pkg.dev
# there, so the VM can reach Google APIs and the Artifact Registry Ubuntu mirror
# and nothing else. Packer reaches the VM over IAP, admitted by the one ingress
# rule below. It cannot lean on the org hierarchical policy's IAP rule: that
# lives in network/, which deploys after the image exists.
#
# The sibling gcp-supply-chain-security bake gave its build VM a public IP for
# apt. This one does not need one, because apt reads the mirror.

locals {
  gov           = data.terraform_remote_state.governance.outputs
  project       = local.gov.image_project_id
  private_vip   = ["199.36.153.8", "199.36.153.9", "199.36.153.10", "199.36.153.11"]
  private_range = "199.36.153.8/30"
}

check "image_project_vended" {
  assert {
    condition     = local.project != null
    error_message = "The governance root did not vend the image project (vend_image_project = false)."
  }
}

resource "google_compute_network" "bake" {
  # checkov:skip=CKV2_GCP_18: the VPC rules below are attached; the check looks
  # for a firewall policy association, and the org hierarchical policy covers
  # ingress for every VPC in the org.
  project                         = local.project
  name                            = "vpc-bake"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = true
}

resource "google_compute_subnetwork" "bake" {
  project                  = local.project
  name                     = "snet-bake-${var.region}"
  network                  = google_compute_network.bake.id
  region                   = var.region
  ip_cidr_range            = "10.250.0.0/28"
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# The only route out, and it goes to Google, not the internet.
resource "google_compute_route" "private_google" {
  project          = local.project
  name             = "rt-bake-private-google"
  network          = google_compute_network.bake.name
  dest_range       = local.private_range
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000
}

resource "google_compute_firewall" "allow_private_google" {
  project            = local.project
  name               = "allow-egress-private-google"
  network            = google_compute_network.bake.name
  direction          = "EGRESS"
  priority           = 1000
  destination_ranges = [local.private_range]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# SSH from Google's IAP range only, and only to the bake VM's identity.
resource "google_compute_firewall" "allow_iap_ssh" {
  project                 = local.project
  name                    = "allow-iap-ssh-bake"
  network                 = google_compute_network.bake.name
  direction               = "INGRESS"
  priority                = 1000
  source_ranges           = ["35.235.240.0/20"]
  target_service_accounts = [google_service_account.bake.email]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Belt and braces with the missing route: if someone adds a default route
# later, egress still stops here.
resource "google_compute_firewall" "deny_egress" {
  project            = local.project
  name               = "deny-all-egress"
  network            = google_compute_network.bake.name
  direction          = "EGRESS"
  priority           = 65000
  destination_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

locals {
  private_zones = {
    googleapis = "googleapis.com."
    pkgdev     = "pkg.dev."
  }
}

resource "google_dns_managed_zone" "private_google" {
  for_each = local.private_zones

  project     = local.project
  name        = "bake-${each.key}"
  dns_name    = each.value
  description = "Resolves ${each.value} to private.googleapis.com for the bake VPC."
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.bake.id
    }
  }
}

resource "google_dns_record_set" "private_google_apex" {
  for_each = local.private_zones

  project      = local.project
  managed_zone = google_dns_managed_zone.private_google[each.key].name
  name         = each.key == "googleapis" ? "private.googleapis.com." : each.value
  type         = "A"
  ttl          = 300
  rrdatas      = local.private_vip
}

resource "google_dns_record_set" "private_google_wildcard" {
  for_each = local.private_zones

  project      = local.project
  managed_zone = google_dns_managed_zone.private_google[each.key].name
  name         = "*.${each.value}"
  type         = "CNAME"
  ttl          = 300
  rrdatas      = ["private.googleapis.com."]
}
