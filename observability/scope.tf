# One metrics scope: the logging project is the scoping project, so a policy
# there can alert on metrics that live in the app and host projects. No
# per-project alert sprawl, one place to read.
#
# Cloud Monitoring is not a VPC-SC restricted service here (network/ restricts
# BigQuery, KMS, Pub/Sub, Secret Manager, Cloud SQL Admin, Storage), so the
# scope crosses the perimeter without an ingress rule.

resource "google_monitoring_monitored_project" "scope" {
  for_each = local.monitored

  metrics_scope = "locations/global/metricsScopes/${local.logging_project}"
  name          = each.value
}
