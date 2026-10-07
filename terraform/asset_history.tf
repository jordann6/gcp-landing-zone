# Config history: the Cloud Asset Inventory equivalent of AWS Config.
#
# AWS Config records what a resource looked like and when it changed. Cloud Asset
# Inventory does both halves natively:
#
#   feeds    push a message to Pub/Sub the moment an IAM policy, an org policy, or
#            a firewall resource changes anywhere in the organization. This is the
#            "what just changed" stream.
#   export   a scheduled snapshot of the same content into BigQuery, one daily
#            partition per run. This is the "what did it look like on day N, and
#            when did it change" store, queryable with SQL.
#
# Both live in the logging project, outside the blast radius of what they record.
# Cost is pennies: a lab org has a few hundred assets, feed messages are free to
# generate, and the three scheduler jobs fall in the free tier.

locals {
  # Feeds watch the hierarchy for IAM and org policy, and firewall policy and
  # rule resources for network changes.
  hierarchy_asset_types = [
    "cloudresourcemanager.googleapis.com/Organization",
    "cloudresourcemanager.googleapis.com/Folder",
    "cloudresourcemanager.googleapis.com/Project",
  ]

  firewall_asset_types = [
    # Network firewall policies (fwp-*) are FirewallPolicy in Asset Inventory;
    # NetworkFirewallPolicy is not a supported asset type.
    "compute.googleapis.com/FirewallPolicy",
    "compute.googleapis.com/Firewall",
  ]

  asset_feeds = {
    iam-policy = { content_type = "IAM_POLICY", asset_types = local.hierarchy_asset_types }
    org-policy = { content_type = "ORG_POLICY", asset_types = local.hierarchy_asset_types }
    firewall   = { content_type = "RESOURCE", asset_types = local.firewall_asset_types }
  }
}

# The Cloud Asset service agent of the logging project publishes feed messages
# and writes the BigQuery export. It exists once the API is enabled.
resource "google_project_service_identity" "cloudasset" {
  provider = google-beta

  project = module.logging_project.project_id
  service = "cloudasset.googleapis.com"
}

resource "google_pubsub_topic" "asset_changes" {
  project      = module.logging_project.project_id
  name         = "asset-changes"
  kms_key_name = google_kms_crypto_key.telemetry.id

  depends_on = [google_kms_crypto_key_iam_member.pubsub_agent]
}

# A subscription keeps the stream readable (the test, a later runbook). Never
# expires: the 31-day inactivity default would silently delete it.
resource "google_pubsub_subscription" "asset_changes" {
  project = module.logging_project.project_id
  name    = "asset-changes-sub"
  topic   = google_pubsub_topic.asset_changes.id

  message_retention_duration = "604800s"
  ack_deadline_seconds       = 20

  expiration_policy {
    ttl = ""
  }
}

resource "google_pubsub_topic_iam_member" "asset_publisher" {
  project = module.logging_project.project_id
  topic   = google_pubsub_topic.asset_changes.name
  role    = "roles/pubsub.publisher"
  member  = google_project_service_identity.cloudasset.member
}

# Every call in this root is billed to the seed project (provider
# billing_project + user_project_override), and the feed API publishes as the
# Cloud Asset agent of THAT project, whatever the feed's own billing_project
# field says. The seed project outlives every feed, which is what the API needs.
data "google_project" "seed" {
  project_id = var.seed_project_id
}

resource "google_pubsub_topic_iam_member" "asset_publisher_seed" {
  project = module.logging_project.project_id
  topic   = google_pubsub_topic.asset_changes.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${data.google_project.seed.number}@gcp-sa-cloudasset.iam.gserviceaccount.com"
}

resource "google_cloud_asset_organization_feed" "changes" {
  for_each = local.asset_feeds

  billing_project = module.logging_project.project_id
  org_id          = var.org_id
  feed_id         = "lz-${each.key}"
  content_type    = each.value.content_type
  asset_types     = each.value.asset_types

  feed_output_config {
    pubsub_destination {
      topic = google_pubsub_topic.asset_changes.id
    }
  }

  depends_on = [
    google_pubsub_topic_iam_member.asset_publisher,
    google_pubsub_topic_iam_member.asset_publisher_seed,
  ]
}

# ---- scheduled export to BigQuery --------------------------------------------

resource "google_bigquery_dataset" "assets" {
  project    = module.logging_project.project_id
  dataset_id = "asset_inventory"
  location   = var.bigquery_location

  description = "Daily Cloud Asset Inventory snapshots (IAM policy, org policy, firewall resources). One partition per run."

  default_partition_expiration_ms = var.log_retention_days * 24 * 60 * 60 * 1000

  # Demo org. In production this is false.
  delete_contents_on_destroy = true

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.telemetry.id
  }

  depends_on = [google_kms_crypto_key_iam_member.bigquery_agent]
}

resource "google_bigquery_dataset_iam_member" "asset_writer" {
  project    = module.logging_project.project_id
  dataset_id = google_bigquery_dataset.assets.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_project_service_identity.cloudasset.member
}

# The export writes load jobs in the project the request is billed to.
resource "google_project_iam_member" "asset_jobs" {
  project = module.logging_project.project_id
  role    = "roles/bigquery.jobUser"
  member  = google_project_service_identity.cloudasset.member
}

resource "google_service_account" "asset_export" {
  project      = module.logging_project.project_id
  account_id   = "sa-asset-export"
  display_name = "Cloud Scheduler caller for the daily asset export"
}

# Read-only at the org: the caller may snapshot assets and nothing else.
resource "google_organization_iam_member" "asset_export" {
  org_id = var.org_id
  role   = "roles/cloudasset.viewer"
  member = google_service_account.asset_export.member
}

locals {
  export_tables = {
    iam_policy = "IAM_POLICY"
    org_policy = "ORG_POLICY"
    resource   = "RESOURCE"
  }
}

resource "google_cloud_scheduler_job" "asset_export" {
  for_each = local.export_tables

  project   = module.logging_project.project_id
  region    = var.region
  name      = "asset-export-${replace(each.key, "_", "-")}"
  schedule  = "0 5 * * *"
  time_zone = "UTC"

  description = "Daily ${each.value} snapshot of the organization into BigQuery."

  http_target {
    http_method = "POST"
    uri         = "https://cloudasset.googleapis.com/v1/organizations/${var.org_id}:exportAssets"
    headers     = { "Content-Type" = "application/json" }

    body = base64encode(jsonencode({
      contentType = each.value
      outputConfig = {
        bigqueryDestination = {
          dataset = "projects/${module.logging_project.project_id}/datasets/${google_bigquery_dataset.assets.dataset_id}"
          table   = each.key
          force   = true
          partitionSpec = {
            partitionKey = "REQUEST_TIME"
          }
        }
      }
    }))

    oauth_token {
      service_account_email = google_service_account.asset_export.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_organization_iam_member.asset_export,
    google_bigquery_dataset_iam_member.asset_writer,
    google_project_iam_member.asset_jobs,
  ]
}
