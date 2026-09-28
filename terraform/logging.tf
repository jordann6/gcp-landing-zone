# Centralized logging.
#
# Two organization sinks with include_children, so every project in the org is
# covered, including projects created after the sinks exist. That last part is
# what makes it a landing zone control rather than a per-project chore.
#
#   BigQuery   partitioned, CMEK, the long-form audit store for SQL questions
#              ("who read that secret last month").
#   Log bucket Log Analytics enabled, the operational view, and the source the
#              org-admin and CIS alert metrics count against (monitoring.tf).
#
# Both land in the logging project in core/, which no workload persona can
# write to: the audit trail lives outside the blast radius of what it audits.

resource "google_bigquery_dataset" "audit" {
  project    = module.logging_project.project_id
  dataset_id = "org_audit_logs"
  location   = var.bigquery_location

  description = "Organization-wide audit and security logs. Partition expiry bounds both storage cost and retention."

  # Bounds cost. Without an expiry this dataset grows forever, and audit log
  # volume is the line item that surprises people on a landing zone.
  default_partition_expiration_ms = var.log_retention_days * 24 * 60 * 60 * 1000

  # This is a demo org. In production this is false and deletion is a
  # deliberate, separately-approved act.
  delete_contents_on_destroy = true

  default_encryption_configuration {
    kms_key_name = google_kms_crypto_key.telemetry.id
  }

  depends_on = [google_kms_crypto_key_iam_member.bigquery_agent]
}

locals {
  # Filtered rather than catch-all: admin activity, data access, system events,
  # and policy denials are the security-relevant streams, and shipping
  # everything else multiplies cost for logs nobody queries.
  audit_filter = <<-EOT
    logName:"cloudaudit.googleapis.com%2Factivity"
    OR logName:"cloudaudit.googleapis.com%2Fdata_access"
    OR logName:"cloudaudit.googleapis.com%2Fsystem_event"
    OR logName:"cloudaudit.googleapis.com%2Fpolicy"
  EOT
}

resource "google_logging_organization_sink" "audit" {
  name             = "org-audit-to-bigquery"
  org_id           = var.org_id
  destination      = "bigquery.googleapis.com/projects/${module.logging_project.project_id}/datasets/${google_bigquery_dataset.audit.dataset_id}"
  include_children = true
  filter           = local.audit_filter

  bigquery_options {
    use_partitioned_tables = true
  }
}

# A sink writes as its own generated service account, which does not exist until
# the sink does. Skipping this grant is the single most common reason a
# correctly-configured sink silently delivers nothing.
resource "google_bigquery_dataset_iam_member" "sink_writer" {
  project    = module.logging_project.project_id
  dataset_id = google_bigquery_dataset.audit.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_organization_sink.audit.writer_identity
}

resource "google_logging_project_bucket_config" "org" {
  project          = module.logging_project.project_id
  location         = var.region
  bucket_id        = "org-audit"
  description      = "Organization audit logs, Log Analytics enabled. Alert metrics count against this bucket."
  retention_days   = var.log_retention_days
  enable_analytics = true

  # Unlocked so the demo can be destroyed. A locked bucket cannot have its
  # retention reduced or be deleted until every entry ages out, which is the
  # production setting and the reason it is not the demo one.
  locked = false
}

resource "google_logging_organization_sink" "bucket" {
  name             = "org-audit-to-log-bucket"
  org_id           = var.org_id
  destination      = "logging.googleapis.com/${google_logging_project_bucket_config.org.id}"
  include_children = true
  filter           = local.audit_filter
}

resource "google_project_iam_member" "bucket_sink_writer" {
  project = module.logging_project.project_id
  role    = "roles/logging.bucketWriter"
  member  = google_logging_organization_sink.bucket.writer_identity
}
