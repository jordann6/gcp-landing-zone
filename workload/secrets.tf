# Secret Manager: the only sanctioned path for a secret, rooted in the CMEK,
# with rotation.
#
# Rotation on GCP is a schedule plus a notification, not a built-in rotator:
# Secret Manager publishes to Pub/Sub when a secret is due, and the consumer
# (a function, a job) mints and adds the new version. The AWS zone uses a
# rotation Lambda for the same job. Here the schedule and topic are real; the
# rotator is the same pattern shipped in azure-secrets-lifecycle and
# aws-secrets-lifecycle, pointed at this topic.

resource "google_pubsub_topic" "secret_rotation" {
  project      = local.project
  name         = "secret-rotation"
  kms_key_name = google_kms_crypto_key.workload["pubsub"].id

  depends_on = [google_kms_crypto_key_iam_member.workload]
}

resource "google_pubsub_topic_iam_member" "secret_rotation" {
  project = local.project
  topic   = google_pubsub_topic.secret_rotation.name
  role    = "roles/pubsub.publisher"
  member  = google_project_service_identity.agents["secretmanager.googleapis.com"].member
}

resource "time_static" "rotation_start" {}

# An empty shell: no version is managed here, so no secret value is ever in
# state. scripts/set-db-password.sh adds the version.
resource "google_secret_manager_secret" "db_password" {
  project   = local.project
  secret_id = "app-db-password"

  replication {
    user_managed {
      replicas {
        location = var.region
        customer_managed_encryption {
          kms_key_name = google_kms_crypto_key.workload["secrets"].id
        }
      }
    }
  }

  rotation {
    rotation_period    = "2592000s" # 30 days
    next_rotation_time = timeadd(time_static.rotation_start.rfc3339, "720h")
  }

  topics {
    name = google_pubsub_topic.secret_rotation.id
  }

  lifecycle {
    # Secret Manager advances next_rotation_time itself after each rotation
    # notification, so the value Terraform wrote is stale by design.
    ignore_changes = [rotation[0].next_rotation_time]
  }

  depends_on = [
    google_kms_crypto_key_iam_member.workload,
    google_pubsub_topic_iam_member.secret_rotation,
  ]
}

# A consumer for the rotation topic so a notification can be read back and
# proved (scripts/test-secrets.sh). The rotator that mints the new version is
# the secrets-lifecycle pattern pointed at this subscription.
resource "google_pubsub_subscription" "secret_rotation" {
  project = local.project
  name    = "secret-rotation-sub"
  topic   = google_pubsub_topic.secret_rotation.id

  message_retention_duration = "86400s"
  ack_deadline_seconds       = 30

  expiration_policy {
    ttl = ""
  }
}
