# The detect layer.
#
# Everything else in this build is preventive. Prevention has a ceiling: it
# stops what you anticipated, and a landing zone with no detection cannot tell
# you when a control was changed, bypassed, or never applied to something that
# arrived by another path.
#
# Security Command Center Standard is free and is all this needs. Premium and
# Enterprise are priced against total asset spend and are emphatically not
# something to enable to see what happens.

resource "google_pubsub_topic" "findings" {
  project      = var.seed_project_id
  name         = "scc-findings"
  labels       = var.labels
  kms_key_name = google_kms_crypto_key.telemetry.id

  depends_on = [google_kms_crypto_key_iam_member.pubsub_agent]
}

# Findings land here for a subscriber that does not exist yet. That is the
# honest state of this build: the pipe is real, the consumer is the next
# project's job.
resource "google_pubsub_subscription" "findings" {
  project = var.seed_project_id
  name    = "scc-findings-sub"
  topic   = google_pubsub_topic.findings.id
  labels  = var.labels

  message_retention_duration = "604800s"
  ack_deadline_seconds       = 20

  expiration_policy {
    # Never expire. The default is 31 days of inactivity, which silently deletes
    # the subscription on a quiet org and takes the audit trail with it.
    ttl = ""
  }
}

resource "google_scc_notification_config" "active_findings" {
  count = var.enable_scc_notifications ? 1 : 0

  config_id    = "active-findings"
  organization = var.org_id
  description  = "Active, unmuted findings streamed to Pub/Sub for automated triage."
  pubsub_topic = google_pubsub_topic.findings.id

  streaming_config {
    # Muted findings are ones a human already judged. Re-notifying on them
    # trains the reader to ignore the stream.
    filter = "state = \"ACTIVE\" AND NOT mute = \"MUTED\""
  }
}

# Budget alerting. A landing zone that governs security but not spend is half a
# landing zone, and cost is the failure mode most likely to actually occur in a
# personal org.
resource "google_pubsub_topic" "budget" {
  project      = var.seed_project_id
  name         = "budget-alerts"
  labels       = var.labels
  kms_key_name = google_kms_crypto_key.telemetry.id

  depends_on = [google_kms_crypto_key_iam_member.pubsub_agent]
}

resource "google_billing_budget" "org" {
  billing_account = var.billing_account
  display_name    = "organization-monthly"

  budget_filter {
    # Whole billing account, so a project created outside the landing zone still
    # counts against the budget.
    calendar_period = "MONTH"
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = var.budget_thresholds
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  # Forecast-based alert as well as actual. Actual spend tells you it already
  # happened; forecast tells you while there is still time to act.
  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    pubsub_topic                     = google_pubsub_topic.budget.id
    schema_version                   = "1.0"
    disable_default_iam_recipients   = false
    monitoring_notification_channels = []
  }
}
