# Customer-managed keys for the workload.
#
# Required, not optional: the prod folder carries gcp.restrictNonCmekServices,
# so GKE, Cloud SQL, Secret Manager, Artifact Registry, and Cloud Storage in
# this project are rejected at the API without a key. One key per purpose, so
# revoking one (say, the database key) does not take the cluster down with it.
#
# Envelope encryption of Kubernetes secrets uses the same key family as
# everything else, which is the "CMK etcd" control from the EKS and AKS roots.

resource "google_kms_key_ring" "workload" {
  project  = local.project
  name     = "workload-${var.env}"
  location = var.region
}

# The replica lives in another region, and a CMEK key must be co-located with
# the resource it protects, so the DR side needs its own ring.
resource "google_kms_key_ring" "replica" {
  count = var.enable_cross_region_replica ? 1 : 0

  project  = local.project
  name     = "workload-${var.env}-dr"
  location = var.replica_region
}

locals {
  keys = {
    gke-secrets = "GKE application-layer secrets encryption (etcd envelope)"
    gke-disk    = "GKE node boot disks"
    sql         = "Cloud SQL primary"
    secrets     = "Secret Manager"
    registry    = "Artifact Registry"
    storage     = "Cloud Storage"
    pubsub      = "Pub/Sub (secret rotation topic)"
  }

  # Which service agent encrypts with which key. Each agent acts as itself, not
  # as the caller, so each needs its own grant. One agent per key, and the IAM
  # resource is keyed on the key name: several of these emails are only known
  # after apply, so they cannot be part of a for_each key.
  key_user = {
    gke-secrets = "serviceAccount:service-${local.number}@container-engine-robot.iam.gserviceaccount.com"
    gke-disk    = "serviceAccount:service-${local.number}@compute-system.iam.gserviceaccount.com"
    sql         = google_project_service_identity.agents["sqladmin.googleapis.com"].member
    secrets     = google_project_service_identity.agents["secretmanager.googleapis.com"].member
    registry    = google_project_service_identity.agents["artifactregistry.googleapis.com"].member
    storage     = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
    pubsub      = google_project_service_identity.agents["pubsub.googleapis.com"].member
  }
}

resource "google_kms_crypto_key" "workload" {
  # checkov:skip=CKV_GCP_82: prevent_destroy is off because this is a
  # deploy-demo-destroy build with a documented teardown.
  for_each = local.keys

  name            = each.key
  key_ring        = google_kms_key_ring.workload.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_kms_crypto_key" "sql_replica" {
  # checkov:skip=CKV_GCP_82: deploy-demo-destroy build, documented teardown.
  count = var.enable_cross_region_replica ? 1 : 0

  name            = "sql-replica"
  key_ring        = google_kms_key_ring.replica[0].id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s"

  lifecycle {
    prevent_destroy = false
  }
}

resource "google_kms_crypto_key_iam_member" "workload" {
  for_each = local.keys

  crypto_key_id = google_kms_crypto_key.workload[each.key].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = local.key_user[each.key]

  depends_on = [time_sleep.agents]
}

resource "google_kms_crypto_key_iam_member" "sql_replica" {
  count = var.enable_cross_region_replica ? 1 : 0

  crypto_key_id = google_kms_crypto_key.sql_replica[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = google_project_service_identity.agents["sqladmin.googleapis.com"].member

  depends_on = [time_sleep.agents]
}
