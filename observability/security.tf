# SCC findings to the ops channel.
#
# The scc-findings topic and the SCC notification config live in terraform/
# (detect.tf). Findings only flow once Security Command Center is activated for
# the organization, which is console-only: there is no CLI or API path to
# activate it, so everything here is gated behind enable_scc_alerts (default
# false) and the matching enable_scc_notifications in terraform/.
#
# Pub/Sub cannot send email, so the alert fires on messages published to the
# topic and points the reader at the subscription. The detail of each finding
# is pulled with the command in the documentation. Incident wiring (item 2d)
# consumes the same topic.

resource "google_monitoring_alert_policy" "scc_findings" {
  count = var.enable_scc_alerts ? 1 : 0

  project      = local.logging_project
  display_name = "lz-ops-scc-high-critical-finding"
  combiner     = "OR"

  conditions {
    display_name = "A HIGH or CRITICAL SCC finding was published."

    condition_threshold {
      filter          = "metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\" AND resource.type=\"pubsub_topic\" AND resource.labels.topic_id=\"scc-findings\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = google_monitoring_notification_channel.ops[*].id

  documentation {
    content   = "Read it: `gcloud pubsub subscriptions pull scc-findings-sub --project=${local.logging_project} --limit=5`. The stream is filtered to HIGH and CRITICAL in terraform/detect.tf."
    mime_type = "text/markdown"
  }

  depends_on = [google_monitoring_monitored_project.scope]
}
