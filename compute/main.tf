# The management VM: one hardened instance, the same contract in all three
# landing zones.
#
#   built from    the golden image family (image project), the only image
#                 compute.trustedImageProjects admits here
#   reached by    IAP + OS Login only; no external IP, no SSH keys in metadata
#   patched by    OS Config (patching.tf), reading the Artifact Registry mirror
#   placed in     the prod app project on the restricted Shared VPC subnet,
#                 so it sits INSIDE the VPC Service Controls perimeter, on
#                 purpose: it is the operator's foothold for the restricted
#                 tier and the target for the forensics and remediation
#                 runbooks, and the restricted PSC bundle is its only path to
#                 Google APIs
#
# Mirrors azure-landing-zone/compute (run-command) and the AWS SSM-managed
# instance.

locals {
  gov = data.terraform_remote_state.governance.outputs
  net = data.terraform_remote_state.network.outputs
  img = data.terraform_remote_state.image.outputs

  app     = local.gov.app_projects["app-${var.env}"]
  project = local.app.project_id
  vpc     = local.net.vpcs[local.app.host]

  image = "projects/${local.img.project_id}/global/images/family/${var.image_family}"

  labels = {
    environment = var.env
    layer       = "compute"
    role        = "mgmt"
  }
}

check "lands_on_restricted_tier" {
  assert {
    condition     = local.vpc.restricted
    error_message = "The management VM belongs on the restricted tier, inside the perimeter."
  }
}

resource "google_service_account" "mgmt" {
  project      = local.project
  account_id   = "sa-mgmt-vm"
  display_name = "Management VM (logs, metrics, mirror read)"
}

resource "google_project_iam_member" "mgmt" {
  for_each = toset(["roles/logging.logWriter", "roles/monitoring.metricWriter"])

  project = local.project
  role    = each.value
  member  = google_service_account.mgmt.member
}

# apt on the VM reads the mirror as this identity; OS Config patch runs
# depend on it.
resource "google_artifact_registry_repository_iam_member" "mgmt_reads_mirror" {
  for_each = local.img.apt_mirror

  project    = local.img.project_id
  location   = var.region
  repository = each.value.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.mgmt.member
}

resource "google_compute_instance" "mgmt" {
  # checkov:skip=CKV_GCP_38: CSEK means supplying raw key material per request;
  # the VM holds no data. The prod CMEK policy does not cover Compute.
  project      = local.project
  name         = "${var.env}-mgmt"
  machine_type = var.machine_type
  zone         = var.zone
  tags         = ["mgmt"]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = local.image
      size  = 20
      type  = "pd-balanced"
    }
  }

  # No access_config: no external IP. The org policy would reject one anyway.
  network_interface {
    subnetwork = local.vpc.subnet
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
    email  = google_service_account.mgmt.email
    scopes = ["cloud-platform"]
  }

  depends_on = [
    google_project_iam_member.mgmt,
    google_artifact_registry_repository_iam_member.mgmt_reads_mirror,
  ]
}

# Operator access for make test-compute, scoped to this one project.
resource "google_project_iam_member" "operators" {
  for_each = {
    for pair in setproduct(var.operators, [
      "roles/iap.tunnelResourceAccessor",
      "roles/compute.osAdminLogin",
      "roles/compute.viewer",
      "roles/osconfig.patchJobExecutor",
      "roles/osconfig.patchDeploymentViewer",
    ]) : "${pair[0]}/${pair[1]}" => { member = pair[0], role = pair[1] }
  }

  project = local.project
  role    = each.value.role
  member  = each.value.member
}

# OS Login as a user needs actAs on the VM's service account.
resource "google_service_account_iam_member" "operators" {
  for_each = toset(var.operators)

  service_account_id = google_service_account.mgmt.name
  role               = "roles/iam.serviceAccountUser"
  member             = each.value
}
