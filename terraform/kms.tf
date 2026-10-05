# Customer-managed encryption for the centralized telemetry.
#
# The audit dataset and the two Pub/Sub topics (SCC findings, budget alerts) are
# where this layer accumulates sensitive material: who did what, and what the
# scanner thinks is wrong. They share one key, so a single disable revokes read
# access to the org's entire audit trail and finding stream at once, with no IAM
# edit and nothing deleted.
#
# The key lives in the logging project, next to what it protects, not in the
# seed: the seed holds only what is needed to rebuild the org.
#
# BigQuery and Pub/Sub both require the key to be co-located with the resource,
# which is why the dataset defaults to a region rather than the US multi-region.

resource "google_kms_key_ring" "telemetry" {
  project = module.logging_project.project_id
  name    = "telemetry"

  # Key rings are permanent: they cannot be deleted or moved, and the location
  # is fixed at creation. Destroy removes it from state and leaves it in place,
  # costing nothing. Deleting the logging project takes it with it.
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
# needs its own grant on the key. A missing grant fails the resource creation
# outright rather than silently falling back to Google-managed keys.
data "google_bigquery_default_service_account" "logging" {
  project = module.logging_project.project_id
}

resource "google_kms_crypto_key_iam_member" "bigquery_agent" {
  crypto_key_id = google_kms_crypto_key.telemetry.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_bigquery_default_service_account.logging.email}"
}

# The Pub/Sub service agent is provisioned when the API is enabled, which the
# project factory does before this grant can run.
resource "google_kms_crypto_key_iam_member" "pubsub_agent" {
  crypto_key_id = google_kms_crypto_key.telemetry.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${module.logging_project.project_number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}
