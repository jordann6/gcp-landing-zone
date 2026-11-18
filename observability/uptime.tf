# Edge uptime, from outside: Google's checkers in several regions request the
# anycast IP every minute, through the load balancer and Cloud Armor, the same
# path a user takes. Two or more regions failing for a minute opens
# lz-ops-edge-uptime, which emails ops and, with the incident channel on, makes
# the handler's web_heal scale the Deployment back to its floor or restart it.
#
# The AWS zone's uptime/ root does this with a scheduled Lambda; here the
# checker is managed, so there is no code to run, only the check and the policy.

data "terraform_remote_state" "edge" {
  count = var.enable_edge_uptime ? 1 : 0

  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "landing-zone/edge"
    impersonate_service_account = var.terraform_service_account
  }
}

resource "google_monitoring_uptime_check_config" "edge" {
  count = var.enable_edge_uptime ? 1 : 0

  project      = local.logging_project
  display_name = "lz-edge"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path         = "/"
    port         = 80
    use_ssl      = false
    validate_ssl = false
    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = local.logging_project
      host       = data.terraform_remote_state.edge[0].outputs.address.ip
    }
  }

  depends_on = [google_monitoring_monitored_project.scope]
}

resource "google_monitoring_alert_policy" "edge_uptime" {
  count = var.enable_edge_uptime ? 1 : 0

  project      = local.logging_project
  display_name = "lz-ops-edge-uptime"
  combiner     = "OR"

  conditions {
    display_name = "Edge failing uptime checks from 2 or more regions."

    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND resource.type=\"uptime_url\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.edge[0].uptime_check_id}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      duration        = "60s"

      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.host"]
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = concat(
    google_monitoring_notification_channel.ops[*].id,
    google_monitoring_notification_channel.incident[*].id,
  )

  documentation {
    content   = "The edge stopped answering 2xx from multiple checker regions. With the incident channel on, the handler's web_heal acts on app/web."
    mime_type = "text/markdown"
  }
}
