# FinOps: the Cloud Billing export lands here, and the cost views sit on top.
#
# In the seed project, because it is the one standing project. Every other
# landing-zone project is vended and destroyed per session, and a billing export
# pointed at a dataset that gets deleted stops silently; here the history keeps
# accumulating across sessions, which is the point of an export.
#
# ONE MANUAL STEP, console only (Google offers no API, gcloud or Terraform path):
# Billing > Billing export > BigQuery export > Standard usage cost > Edit
# settings > project = this seed project, dataset = billing_export. Google then
# creates gcp_billing_export_v1_<BILLING_ACCOUNT> and starts backfilling the
# current and previous month. Only after the table exists can the views be
# created, so they are gated by enable_billing_views. scripts/finops-report.sh
# checks for the table and says which step is missing.
#
# Views, all over net cost (cost plus credits, which are negative):
#   cost_daily       day x project x service x SKU, with the cost_center label
#                    from the resource, falling back to the project's
#   cost_by_label    month x cost_center: the chargeback view; "untagged" is
#                    the spend nobody owns
#   label_coverage   month: share of net cost carrying a cost_center
#   cost_anomalies   project x service days that cost more than twice their
#                    trailing 7-day average and more than $1

resource "google_bigquery_dataset" "billing_export" {
  # checkov:skip=CKV_GCP_81: Cloud Billing writes into this dataset itself and
  # does not support CMEK on the export destination; Google-managed encryption.
  project     = google_project.seed.project_id
  dataset_id  = "billing_export"
  location    = var.billing_export_location
  description = "Cloud Billing standard usage cost export (configured once in the console)."
  labels      = var.labels

  depends_on = [google_project_service.seed]
}

resource "google_bigquery_dataset" "finops" {
  # checkov:skip=CKV_GCP_81: views only, no stored data.
  project     = google_project.seed.project_id
  dataset_id  = "finops"
  location    = var.billing_export_location
  description = "Cost views over billing_export: daily cost, chargeback by cost_center, label coverage, anomalies."
  labels      = var.labels

  depends_on = [google_project_service.seed]
}

locals {
  billing_table = "`${google_project.seed.project_id}.${google_bigquery_dataset.billing_export.dataset_id}.gcp_billing_export_v1_${replace(var.billing_account, "-", "_")}`"
  finops        = "${google_project.seed.project_id}.${google_bigquery_dataset.finops.dataset_id}"

  finops_views = {
    cost_daily = <<-SQL
      SELECT
        DATE(usage_start_time) AS day,
        invoice.month AS invoice_month,
        project.id AS project_id,
        service.description AS service,
        sku.description AS sku,
        COALESCE(
          (SELECT value FROM UNNEST(labels) WHERE key = 'cost_center'),
          (SELECT value FROM UNNEST(project.labels) WHERE key = 'cost_center')
        ) AS cost_center,
        SUM(cost) AS cost,
        SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS credits,
        SUM(cost) + SUM(IFNULL((SELECT SUM(c.amount) FROM UNNEST(credits) c), 0)) AS net_cost
      FROM ${local.billing_table}
      GROUP BY day, invoice_month, project_id, service, sku, cost_center
    SQL

    cost_by_label = <<-SQL
      SELECT invoice_month, IFNULL(cost_center, 'untagged') AS cost_center,
        ROUND(SUM(net_cost), 2) AS net_cost
      FROM `${local.finops}.cost_daily`
      GROUP BY invoice_month, cost_center
    SQL

    label_coverage = <<-SQL
      SELECT invoice_month,
        ROUND(SUM(net_cost), 2) AS net_cost,
        ROUND(SUM(IF(cost_center IS NULL, 0, net_cost)), 2) AS tagged_cost,
        ROUND(SAFE_DIVIDE(SUM(IF(cost_center IS NULL, 0, net_cost)), SUM(net_cost)) * 100, 1) AS tagged_percent
      FROM `${local.finops}.cost_daily`
      GROUP BY invoice_month
    SQL

    cost_anomalies = <<-SQL
      WITH d AS (
        SELECT day, project_id, service, SUM(net_cost) AS net_cost
        FROM `${local.finops}.cost_daily`
        GROUP BY day, project_id, service
      ), w AS (
        SELECT *, AVG(net_cost) OVER (
          PARTITION BY project_id, service ORDER BY UNIX_DATE(day)
          RANGE BETWEEN 7 PRECEDING AND 1 PRECEDING) AS trailing_7d
        FROM d
      )
      SELECT day, project_id, service, ROUND(net_cost, 2) AS net_cost,
        ROUND(trailing_7d, 2) AS trailing_7d_avg,
        ROUND(SAFE_DIVIDE(net_cost, trailing_7d), 1) AS ratio
      FROM w
      WHERE net_cost > 1 AND (trailing_7d IS NULL OR net_cost > 2 * trailing_7d)
    SQL
  }
}

resource "google_bigquery_table" "cost_daily" {
  # checkov:skip=CKV_GCP_121: a view holds no data and is regenerated from this file.
  # checkov:skip=CKV_GCP_80: a view holds no data; the export table it reads is Google-managed.
  count = var.enable_billing_views ? 1 : 0

  project             = google_project.seed.project_id
  dataset_id          = google_bigquery_dataset.finops.dataset_id
  table_id            = "cost_daily"
  deletion_protection = false
  labels              = var.labels

  view {
    query          = local.finops_views.cost_daily
    use_legacy_sql = false
  }
}

resource "google_bigquery_table" "finops" {
  # checkov:skip=CKV_GCP_121: a view holds no data and is regenerated from this file.
  # checkov:skip=CKV_GCP_80: a view holds no data; the export table it reads is Google-managed.
  # The other views read cost_daily, so they follow it.
  for_each = var.enable_billing_views ? { for k, v in local.finops_views : k => v if k != "cost_daily" } : {}

  project             = google_project.seed.project_id
  dataset_id          = google_bigquery_dataset.finops.dataset_id
  table_id            = each.key
  deletion_protection = false
  labels              = var.labels

  view {
    query          = each.value
    use_legacy_sql = false
  }

  depends_on = [google_bigquery_table.cost_daily]
}
