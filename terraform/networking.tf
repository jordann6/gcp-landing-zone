# Shared VPC.
#
# One host project owns the network. Workload projects attach as service
# projects and consume subnets they do not own. That splits the two jobs that
# get conflated in flat account models: the network team sets routing, firewall,
# and IP space once, while application teams keep full control of their own
# project's IAM and resources.

module "network_project" {
  source = "./modules/project-factory"

  name            = "network"
  name_prefix     = var.name_prefix
  folder_id       = google_folder.core.name
  billing_account = var.billing_account
  environment     = "shared"
  labels          = var.labels

  apis = [
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "dns.googleapis.com",
    "serviceusage.googleapis.com",
  ]
}

resource "google_compute_shared_vpc_host_project" "host" {
  project = module.network_project.project_id
}

resource "google_compute_network" "shared" {
  project = module.network_project.project_id
  name    = "shared-vpc"

  # No auto subnets. Auto mode creates a subnet in every region with fixed
  # ranges, which forecloses IP planning and quietly extends the footprint into
  # regions the resource locations policy is trying to constrain.
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = false
}

resource "google_compute_subnetwork" "workload" {
  project       = module.network_project.project_id
  name          = "workload-${var.region}"
  network       = google_compute_network.shared.id
  region        = var.region
  ip_cidr_range = var.subnet_cidr

  # Lets instances without external IPs reach Google APIs. Without it, the
  # vmExternalIpAccess deny above would strand every VM, which is the usual
  # reason that policy gets rolled back rather than fixed.
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pod_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.service_cidr
  }
}

# Default-deny ingress at the lowest priority. GCP's implied rules already deny
# ingress, but an explicit rule is what makes the intent auditable and what
# gives flow logs something to attribute a drop to.
resource "google_compute_firewall" "deny_ingress" {
  project     = module.network_project.project_id
  name        = "deny-all-ingress"
  network     = google_compute_network.shared.name
  direction   = "INGRESS"
  priority    = 65534
  description = "Explicit default deny. Anything reachable is reachable because a higher-priority rule says so."

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# SSH only from the IAP forwarding range. There is no public SSH path: the VMs
# have no external IPs, and this range is the only source permitted, so access
# runs through IAP where it is authenticated and logged per session.
resource "google_compute_firewall" "iap_ssh" {
  project     = module.network_project.project_id
  name        = "allow-iap-ssh"
  network     = google_compute_network.shared.name
  direction   = "INGRESS"
  priority    = 1000
  description = "SSH from the IAP TCP forwarding range only. Never from the internet."

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Google-published, fixed range for IAP TCP forwarding.
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["iap-ssh"]

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# Deliberately not built: Cloud NAT. It is the correct way to give private
# instances outbound internet, and it is also the only always-on billed resource
# this design would have, at roughly $0.044 per gateway-hour plus data
# processing. This is a deploy-demo-destroy build, so egress is left unsolved
# and named rather than quietly costing money. See the README.
