# Proof root for the gated GCP CI path. CI applies and destroys this root
# through platform-guardrails tf-apply.yml / tf-destroy.yml, end to end on
# Workload Identity Federation, with no service account key.
#
# It holds only free resources (a custom-mode VPC, one subnet, and a deny-all
# ingress rule) in the seed project. Governance, network, workload, and compute
# stay operator-applied as sa-terraform.

data "google_client_config" "current" {}

resource "google_compute_network" "ci" {
  name                    = "vpc-lz-ci"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"

  lifecycle {
    # The project is implicit (see versions.tf), so refuse to build anywhere
    # but a landing zone seed project.
    precondition {
      condition     = can(regex("^jn-lz-seed-", data.google_client_config.current.project))
      error_message = "ci-proof applies only to the landing zone seed project."
    }
  }
}

# Flow logs on, as everywhere else in the landing zone (CIS 3.8). With nothing
# attached to the subnet there is no traffic to log, so they cost nothing.
resource "google_compute_subnetwork" "ci" {
  name                     = "snet-lz-ci"
  network                  = google_compute_network.ci.id
  region                   = var.region
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# Explicit deny-all ingress at the lowest priority, so the intent is in code
# rather than implied by the VPC's implicit deny.
resource "google_compute_firewall" "deny_all_ingress" {
  name      = "fw-lz-ci-deny-all-ingress"
  network   = google_compute_network.ci.id
  direction = "INGRESS"
  priority  = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}
