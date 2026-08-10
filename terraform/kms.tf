# Customer-managed encryption for the centralized telemetry.
#
# The audit dataset and the findings topic are the two places in this build that
# accumulate sensitive material: who did what, and what the scanner thinks is
# wrong. Both are encrypted with one key, so a single disable revokes read
# access to the org's entire audit trail and finding stream at once, with no IAM
# edit and nothing deleted.
#
# One key ring, one region, shared by BigQuery and Pub/Sub. Both services
# require the key to be co-located with the resource, which is why the dataset
# defaults to a region rather than the US multi-region.

resource "google_kms_key_ring" "telemetry" {
  project = var.seed_project_id
  name    = "telemetry"

  # Key rings are permanent: they cannot be deleted or moved, and the location
  # is fixed at creation. Destroy removes it from state and leaves it in place,
  # costing nothing. Documented in the README teardown section.
  location = var.region
}

resource "google_kms_crypto_key" "telemetry" {
  # checkov:skip=CKV_GCP_82: prevent_destroy is off because this is a
  # deploy-demo-destroy build with a documented teardown. In production this
  # check should hold.
  name     = "telemetry"
  key_ring = google_kms_key_ring.telemetry.id
  purpose  = "ENCRYPT_DECRYPT"

  rotation_period = "7776000s" # 90 days

  version_template {
    algorithm        = "GOOGLE_SYMMETRIC_ENCRYPTION"
    protection_level = "SOFTWARE"
  }

  lifecycle {
    prevent_destroy = false
  }
}

# Each service encrypts as its own service agent, not as the caller, so each
# needs its own grant on the key. A missing grant here fails the resource
# creation outright rather than silently falling back to Google-managed keys.
data "google_bigquery_default_service_account" "logging" {
  project = module.logging_project.project_id
}

resource "google_kms_crypto_key_iam_member" "bigquery_agent" {
  crypto_key_id = google_kms_crypto_key.telemetry.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_bigquery_default_service_account.logging.email}"
}

data "google_project" "seed" {
  project_id = var.seed_project_id
}

resource "google_kms_crypto_key_iam_member" "pubsub_agent" {
  crypto_key_id = google_kms_crypto_key.telemetry.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.seed.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
