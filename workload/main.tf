# The paved road: a prod workload landed on the landing zone.
#
# Nothing here creates a project, a network, or a policy. The project was vended
# by the governance root into the prod folder, where it inherited every org
# constraint plus prod's CMEK requirement. The subnet, the PSA range, and the
# default-deny firewall policy came from the network root. This root adds only
# what a workload team owns, and every control it relies on is one it could not
# switch off if it tried.
#
# Mirrors aws-landing-zone/workload (EKS + RDS Multi-AZ) and
# azure-landing-zone/workload (AKS + PostgreSQL HA): same contract, GCP-native
# mechanisms.

locals {
  gov = data.terraform_remote_state.governance.outputs
  net = data.terraform_remote_state.network.outputs

  app_key = "app-${var.env}"
  app     = local.gov.app_projects[local.app_key]
  project = local.app.project_id
  number  = local.app.number

  vpc_key = local.app.host
  vpc     = local.net.vpcs[local.vpc_key]

  labels = {
    managed-by  = "terraform"
    project     = "gcp-landing-zone"
    owner       = var.owner
    cost_center = var.cost_center
    environment = var.env
    layer       = "workload"
  }
}

check "lands_on_restricted_tier" {
  assert {
    condition     = local.vpc.restricted
    error_message = "The workload must land on a restricted host (set restricted = true for this environment in the governance root). GKE ranges and the PSA range exist only there."
  }
}

# Service agents that some CMEK grants below name. Asking for each identity
# forces the agent to exist; otherwise the grant races the agent's lazy creation.
resource "google_project_service_identity" "agents" {
  provider = google-beta
  for_each = toset([
    "artifactregistry.googleapis.com",
    "container.googleapis.com",
    "pubsub.googleapis.com",
    "secretmanager.googleapis.com",
    "sqladmin.googleapis.com",
  ])

  project = local.project
  service = each.value
}

data "google_storage_project_service_account" "gcs" {
  project = local.project
}

# IAM on a freshly created service agent takes a short while to propagate.
resource "time_sleep" "agents" {
  depends_on      = [google_project_service_identity.agents]
  create_duration = "30s"
}
