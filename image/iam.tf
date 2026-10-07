# Identities for the bake, and who may read the golden image.

# The bake VM's identity. It needs to read the mirror and write its own logs,
# nothing else. Packer attaches it so apt can authenticate to Artifact Registry
# through the metadata server, which is how ar+https gets a token without a key.
resource "google_service_account" "bake" {
  project      = local.project
  account_id   = "sa-image-bake"
  display_name = "Packer bake VM (mirror read only)"
}

resource "google_artifact_registry_repository_iam_member" "bake_reads_mirror" {
  for_each = google_artifact_registry_repository.ubuntu

  project    = local.project
  location   = each.value.location
  repository = each.value.name
  role       = "roles/artifactregistry.reader"
  member     = google_service_account.bake.member
}

resource "google_project_iam_member" "bake_logs" {
  project = local.project
  role    = "roles/logging.logWriter"
  member  = google_service_account.bake.member
}

# Booting an image from another project needs compute.imageUser on the project
# that owns it, held by the consuming project's Compute service agent. Missing
# it does not read as forbidden: the API reports the image as not found.
locals {
  consumers = merge(
    { for k, h in local.gov.host_projects : k => h.number },
    { for k, a in local.gov.app_projects : k => a.number },
  )
}

resource "google_project_iam_member" "image_users" {
  for_each = local.consumers

  project = local.project
  role    = "roles/compute.imageUser"
  member  = "serviceAccount:service-${each.value}@compute-system.iam.gserviceaccount.com"
}

# Packer runs as sa-image-builder, not as the operator. Two reasons: a service
# account always has an OS Login POSIX account (sa_<id>), where a consumer
# Google account outside the org's directory does not get one per project and
# Packer's key import fails with "no PosixAccounts available"; and it keeps the
# operator's only grant here the same as everywhere else in the landing zone,
# token creation on a service account.
resource "google_service_account" "builder" {
  project      = local.project
  account_id   = "sa-image-builder"
  display_name = "Packer image builder"
}

locals {
  builder_roles = [
    "roles/compute.instanceAdmin.v1",
    "roles/compute.storageAdmin",
    "roles/compute.osAdminLogin",
    "roles/iap.tunnelResourceAccessor",
  ]
}

resource "google_project_iam_member" "builder" {
  for_each = toset(local.builder_roles)

  project = local.project
  role    = each.value
  member  = google_service_account.builder.member
}

# The builder attaches the bake SA to the bake VM.
resource "google_service_account_iam_member" "builder_act_as_bake" {
  service_account_id = google_service_account.bake.name
  role               = "roles/iam.serviceAccountUser"
  member             = google_service_account.builder.member
}

resource "google_service_account_iam_member" "operators_impersonate_builder" {
  for_each = toset(var.operators)

  service_account_id = google_service_account.builder.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = each.value
}
