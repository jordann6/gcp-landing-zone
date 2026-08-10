# Centralized logging.
#
# An organization sink with include_children captures logs from every project in
# the org, including projects created after the sink exists. That last part is
# what makes it a landing zone control rather than a per-project chore: a
# project vended tomorrow is already covered.

module "logging_project" {
  source = "./modules/project-factory"

  name            = "logging"
  name_prefix     = var.name_prefix
  folder_id       = google_folder.core.name
  billing_account = var.billing_account
  environment     = "shared"
  labels          = var.labels

  apis = [
    "bigquery.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "logging.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ]
}

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

  labels = var.labels

  depends_on = [google_kms_crypto_key_iam_member.bigquery_agent]
}

# The sink that does the work. Filtered rather than catch-all: admin activity,
# data access, system events, and policy denials are the security-relevant
# streams, and shipping everything else multiplies cost for logs nobody queries.
resource "google_logging_organization_sink" "audit" {
  name             = "org-audit-to-bigquery"
  org_id           = var.org_id
  destination      = "bigquery.googleapis.com/projects/${module.logging_project.project_id}/datasets/${google_bigquery_dataset.audit.dataset_id}"
  include_children = true

  filter = <<-EOT
    logName:"cloudaudit.googleapis.com%2Factivity"
    OR logName:"cloudaudit.googleapis.com%2Fdata_access"
    OR logName:"cloudaudit.googleapis.com%2Fsystem_event"
    OR logName:"cloudaudit.googleapis.com%2Fpolicy"
  EOT

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
