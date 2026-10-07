# Bootstrap layer.
#
# Creates the seed project and the state bucket the landing zone itself is
# stored in. The seed project sits outside the hierarchy the landing zone
# builds, on purpose: the thing that can rebuild the org must not live inside
# the part of the org it manages.

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  seed_project_id = "${var.name_prefix}-seed-${random_id.suffix.hex}"

  # The seed project is the quota project for every call the landing zone makes
  # (billing_project + user_project_override in each root), so any API a root
  # touches has to be enabled here, not only in the project that holds the
  # resource. Enabling an API is free; a missing one fails with SERVICE_DISABLED
  # on a project ID that does not look related to the resource being created.
  seed_apis = [
    "accesscontextmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "backupdr.googleapis.com",
    "bigquery.googleapis.com",
    "billingbudgets.googleapis.com",
    "binaryauthorization.googleapis.com",
    "cloudasset.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "containeranalysis.googleapis.com",
    "dns.googleapis.com",
    "essentialcontacts.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "orgpolicy.googleapis.com",
    "osconfig.googleapis.com",
    "oslogin.googleapis.com",
    "privilegedaccessmanager.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "securitycenter.googleapis.com",
    "servicenetworking.googleapis.com",
    "serviceusage.googleapis.com",
    "sqladmin.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ]
}

resource "google_project" "seed" {
  name            = local.seed_project_id
  project_id      = local.seed_project_id
  org_id          = var.org_id
  billing_account = var.billing_account
  labels          = merge(var.labels, { layer = "seed" })

  deletion_policy     = "DELETE"
  auto_create_network = false
}

resource "google_project_service" "seed" {
  for_each = toset(local.seed_apis)

  project            = google_project.seed.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_project_iam_audit_config" "seed" {
  project = google_project.seed.project_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
    content {
      log_type = audit_log_config.value
    }
  }
}

resource "google_storage_bucket" "state_logs" {
  # checkov:skip=CKV_GCP_62: log bucket, so access logging terminates here.
  name     = "${local.seed_project_id}-tfstate-logs"
  project  = google_project.seed.project_id
  location = var.state_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.seed]
}

resource "google_storage_bucket" "state" {
  name     = "${local.seed_project_id}-tfstate"
  project  = google_project.seed.project_id
  location = var.state_bucket_location

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy_state

  versioning {
    enabled = true
  }

  logging {
    log_bucket        = google_storage_bucket.state_logs.name
    log_object_prefix = "tfstate/"
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.seed]
}
