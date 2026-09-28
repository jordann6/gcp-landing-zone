# Shared VPC access for service projects.
#
# Subnet-level networkUser rather than project-level: a service project can use
# its environment's subnet and nothing else in the host, which is the
# least-privilege form of Shared VPC.
#
# Three identities per service project need the subnet, and missing any one of
# them fails a different resource later with an error that does not mention
# Shared VPC:
#   the Google APIs service agent  managed instance groups (GKE node pools)
#   the GKE service agent          the cluster itself
#   the Compute default SA         plain VMs created in the service project

locals {
  app_subnet = {
    for k, a in local.gov.app_projects : k => {
      number     = a.number
      host_key   = a.host
      host       = local.hosts[a.host].project_id
      restricted = local.hosts[a.host].restricted
    }
  }

  app_subnet_members = merge([
    for k, a in local.app_subnet : {
      "${k}/cloudservices" = { app = k, member = "serviceAccount:${a.number}@cloudservices.gserviceaccount.com" }
      "${k}/gke"           = { app = k, member = "serviceAccount:service-${a.number}@container-engine-robot.iam.gserviceaccount.com" }
      "${k}/compute"       = { app = k, member = "serviceAccount:${a.number}-compute@developer.gserviceaccount.com" }
    }
  ]...)
}

resource "google_compute_subnetwork_iam_member" "app" {
  for_each = local.app_subnet_members

  project    = local.app_subnet[each.value.app].host
  region     = var.region
  subnetwork = google_compute_subnetwork.workload[local.app_subnet[each.value.app].host_key].name
  role       = "roles/compute.networkUser"
  member     = each.value.member
}

# GKE in a service project also needs, on the host project:
#   hostServiceAgentUser  to use the host's GKE service agent for node networking
#   securityAdmin         to create the classic firewall rules GKE manages
# securityAdmin is broader than ideal. The alternative is pre-creating GKE's
# rules by hand and letting the cluster emit warnings forever; the blueprint
# takes the same trade, scoped to the one restricted host.
resource "google_project_iam_member" "gke_host_agent" {
  for_each = { for k, a in local.app_subnet : k => a if a.restricted }

  project = each.value.host
  role    = "roles/container.hostServiceAgentUser"
  member  = "serviceAccount:service-${each.value.number}@container-engine-robot.iam.gserviceaccount.com"
}

resource "google_project_iam_member" "gke_host_firewall" {
  # checkov:skip=CKV_GCP_42: the GKE service agent creating its own firewall
  # rules in the host project is the documented Shared VPC model; see above.
  for_each = { for k, a in local.app_subnet : k => a if a.restricted }

  project = each.value.host
  role    = "roles/compute.securityAdmin"
  member  = "serviceAccount:service-${each.value.number}@container-engine-robot.iam.gserviceaccount.com"
}
