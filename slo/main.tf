# An SLO on a Cloud Run service, with multi-window burn-rate alerting.
#
#   orders-api (Cloud Run)  run.googleapis.com/request_count
#   SLI                     2xx / all requests (request-based, good_total_ratio)
#   SLO                     99% over a rolling 28 days (error budget 1%)
#   page                    burn > 14.4x over 1h AND over 5m   (budget gone in ~2 days)
#   ticket                  burn > 6x    over 6h AND over 30m  (budget gone in ~5 days)
#
# The pairs are the multiwindow, multi-burn-rate alerts from the Google SRE
# workbook: the long window says the burn is significant, the short window says
# it is still happening, so the page clears soon after the fault does.
#
# Everything is in the app project with the metric, including its own email
# channel: an alert policy can only notify channels in its own project.
#
# Private by construction: ingress is all (so the operator can generate load
# from outside), but the only invoker is sa-terraform and nothing binds allUsers.
# The load in scripts/test-slo.sh carries an identity token.

locals {
  gov     = data.terraform_remote_state.governance.outputs
  wl      = data.terraform_remote_state.workload.outputs
  project = local.gov.app_projects["app-${var.env}"].project_id
  deploy  = var.image != ""
  service = "orders-api"
}

resource "google_service_account" "orders" {
  project      = local.project
  account_id   = "sa-orders-api"
  display_name = "orders-api (runtime, no grants)"
}

resource "google_cloud_run_v2_service" "orders" {
  count = local.deploy ? 1 : 0

  project             = local.project
  name                = local.service
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account = google_service_account.orders.email

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    containers {
      image = var.image

      env {
        name  = "FAULT_PERCENT"
        value = "0"
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "256Mi"
        }
      }

      startup_probe {
        http_get {
          path = "/healthz"
        }
      }
    }
  }

  lifecycle {
    # scripts/test-slo.sh injects the fault with a new revision and restores it;
    # a re-apply between the two must not fight it.
    ignore_changes = [template[0].containers[0].env, client, client_version]
  }
}

resource "google_cloud_run_v2_service_iam_member" "load" {
  count = local.deploy ? 1 : 0

  project  = local.project
  location = var.region
  name     = google_cloud_run_v2_service.orders[0].name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${var.terraform_service_account}"
}

# ---- the SLO ------------------------------------------------------------------

resource "google_monitoring_custom_service" "orders" {
  count = local.deploy ? 1 : 0

  project      = local.project
  service_id   = local.service
  display_name = "orders-api (Cloud Run)"
}

locals {
  request_count = join(" AND ", [
    "metric.type=\"run.googleapis.com/request_count\"",
    "resource.type=\"cloud_run_revision\"",
    "resource.label.\"service_name\"=\"${local.service}\"",
  ])
}

resource "google_monitoring_slo" "availability" {
  count = local.deploy ? 1 : 0

  project      = local.project
  service      = google_monitoring_custom_service.orders[0].service_id
  slo_id       = "availability"
  display_name = "orders-api: ${var.slo_goal * 100}% of requests succeed over ${var.slo_window_days} days"

  goal                = var.slo_goal
  rolling_period_days = var.slo_window_days

  request_based_sli {
    good_total_ratio {
      good_service_filter  = "${local.request_count} AND metric.label.\"response_code_class\"=\"2xx\""
      total_service_filter = local.request_count
    }
  }
}

# ---- burn-rate alerts -----------------------------------------------------------

resource "google_monitoring_notification_channel" "email" {
  project      = local.project
  display_name = "orders-api SLO pages"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

locals {
  burn_alerts = {
    "fast-burn" = { threshold = 14.4, long = "3600s", short = "300s", what = "page: at this rate the 28-day budget is gone in about 2 days" }
    "slow-burn" = { threshold = 6, long = "21600s", short = "1800s", what = "ticket: at this rate the 28-day budget is gone in about 5 days" }
  }
}

resource "google_monitoring_alert_policy" "burn" {
  for_each = local.deploy ? local.burn_alerts : {}

  project      = local.project
  display_name = "lz-slo-orders-api-${each.key}"
  combiner     = "AND"

  dynamic "conditions" {
    for_each = { long = each.value.long, short = each.value.short }
    content {
      display_name = "burn rate > ${each.value.threshold}x over ${conditions.value}"
      condition_threshold {
        filter          = "select_slo_burn_rate(\"${google_monitoring_slo.availability[0].id}\", \"${conditions.value}\")"
        comparison      = "COMPARISON_GT"
        threshold_value = each.value.threshold
        duration        = "0s"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    content   = "orders-api is burning its error budget: ${each.value.what}. Check the latest revision's FAULT_PERCENT and 5xx logs."
    mime_type = "text/markdown"
  }
}
