# Probe VM for the live network tests.
#
# One e2-micro in the prod restricted VPC with no external IP, a dedicated
# service account with no roles, and OS Login. make test reaches it over IAP
# and asserts, from inside the network:
#   - an allowlisted FQDN (github.com) is reachable over 443 through NAT
#   - anything else on the internet is denied by the NGFW egress rule
#   - storage.googleapis.com resolves to the PSC endpoint, not a public address
#
# It is hourly (about $0.01) and hourly-guard flags it, so it is destroyed with
# the rest of this root.
#
# It boots from the golden image family, because compute.trustedImageProjects
# rejects every stock image outside the image project. So make build-image runs
# before make deploy-network.

locals {
  probe_vpc = [for k, v in local.vpcs : k if v.restricted && v.env == "prod"]
  probe     = var.enable_probe_vm && length(local.probe_vpc) > 0 ? { probe = local.vpcs[local.probe_vpc[0]] } : {}

  # The governance output is null when the image project is not vended, and
  # then no allowlist is enforced, so the probe can fall back to stock Debian.
  probe_image = try(local.gov.image_project_id, null) == null ? "debian-cloud/debian-12" : "projects/${local.gov.image_project_id}/global/images/family/${var.image_family}"
}

resource "google_service_account" "probe" {
  for_each = local.probe

  project      = each.value.project
  account_id   = "sa-probe"
  display_name = "Network probe VM (no roles)"
}

resource "google_compute_instance" "probe" {
  # checkov:skip=CKV_GCP_38: CSEK means supplying raw key material per request;
  # a stateless probe VM with no data does not warrant it. Workload data is CMEK.
  for_each = local.probe

  project      = each.value.project
  name         = "probe-${each.value.env}"
  machine_type = "e2-micro"
  zone         = "${var.region}-a"
  tags         = ["probe"]

  boot_disk {
    initialize_params {
      image = local.probe_image
      size  = 20
    }
  }

  # No access_config block: no external IP, which the org policy would reject
  # anyway. Reachable only through IAP.
  network_interface {
    subnetwork = google_compute_subnetwork.workload[local.probe_vpc[0]].id
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    enable-osconfig        = "TRUE"
    block-project-ssh-keys = "TRUE"
  }

  service_account {
    email  = google_service_account.probe[each.key].email
    scopes = ["cloud-platform"]
  }

  depends_on = [google_compute_network_firewall_policy_association.vpc]
}

resource "google_project_iam_member" "probe_operators" {
  for_each = length(local.probe) > 0 ? {
    for pair in setproduct(var.operators, ["roles/iap.tunnelResourceAccessor", "roles/compute.osAdminLogin", "roles/viewer"]) :
    "${pair[0]}/${pair[1]}" => { member = pair[0], role = pair[1] }
  } : {}

  project = local.probe["probe"].project
  role    = each.value.role
  member  = each.value.member
}

# OS Login as a user needs actAs on the VM's service account.
resource "google_service_account_iam_member" "probe_operators" {
  for_each = length(local.probe) > 0 ? toset(var.operators) : []

  service_account_id = google_service_account.probe["probe"].name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}
