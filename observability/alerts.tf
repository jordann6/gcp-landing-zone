# Operational alert policies, all in the logging project (the scoping project),
# all to one ops channel that is separate from the security channel.

resource "google_monitoring_notification_channel" "ops" {
  count = var.ops_alert_email == "" ? 0 : 1

  project      = local.logging_project
  display_name = "Landing zone ops alerts"
  type         = "email"

  labels = {
    email_address = var.ops_alert_email
  }

  depends_on = [google_monitoring_monitored_project.scope]
}

# ---- incident runbook channel -----------------------------------------------
#
# Two policies also publish to the ops-alerts topic, whose push subscription
# (incident/) runs the remediation. Off by default: the topic and handler only
# exist while the incident root is deployed, and it is destroyed after this one.

locals {
  incident_policies = ["gke-node-not-ready", "sql-instance-down"]
}

resource "google_monitoring_notification_channel" "incident" {
  count = var.enable_incident_channel ? 1 : 0

  project      = local.logging_project
  display_name = "Landing zone incident runbooks"
  type         = "pubsub"

  labels = {
    topic = data.terraform_remote_state.incident[0].outputs.ops_topic
  }

  depends_on = [google_monitoring_monitored_project.scope]
}

# Monitoring publishes as its own notification service agent, which only exists
# once a Pub/Sub channel has been created, so the grant follows the channel.
resource "google_pubsub_topic_iam_member" "monitoring_publishes" {
  count = var.enable_incident_channel ? 1 : 0

  project = local.logging_project
  topic   = split("/", data.terraform_remote_state.incident[0].outputs.ops_topic)[3]
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:service-${local.gov.logging_project_number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"

  depends_on = [google_monitoring_notification_channel.incident]
}

# ---- log-based metrics -------------------------------------------------------
#
# User-defined counters in the project that owns the logs. The metrics scope
# makes them readable from the logging project.

resource "google_logging_metric" "ngfw_egress_deny" {
  project = local.host.project_id
  name    = "lz-ngfw-egress-deny"
  filter  = <<-EOT
    logName="projects/${local.host.project_id}/logs/compute.googleapis.com%2Ffirewall"
    AND jsonPayload.disposition="DENIED"
    AND jsonPayload.rule_details.direction="EGRESS"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_logging_metric" "sql_failover" {
  project = local.app.project_id
  name    = "lz-sql-failover"
  filter  = <<-EOT
    resource.type="cloudsql_database"
    AND protoPayload.methodName:"failover"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_logging_metric" "patch_failure" {
  count = var.enable_mgmt_vm_alerts ? 1 : 0

  project = local.app.project_id
  name    = "lz-osconfig-failure"
  filter  = <<-EOT
    logName:"osconfig.googleapis.com"
    AND severity>=ERROR
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

# The incident handler's daily age check logs stale_secret per old secret. Only
# exists while the incident root is deployed.
resource "google_logging_metric" "stale_secret" {
  count = var.enable_incident_channel ? 1 : 0

  project = local.logging_project
  name    = "lz-stale-secret"
  filter  = <<-EOT
    resource.type="cloud_run_revision"
    AND resource.labels.service_name="incident-handler"
    AND jsonPayload.event="stale_secret"
  EOT

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

# ---- threshold policies ------------------------------------------------------

locals {
  # filter is the metric selector. aligner and period shape the series. A policy
  # fires when threshold is crossed for duration.
  threshold_alerts = merge(
    {
      "gke-node-not-ready" = {
        description = "A GKE node reports Ready=False or Unknown for 5 minutes."
        filter      = "metric.type=\"kubernetes.io/node/status_condition\" AND resource.type=\"k8s_node\" AND metric.labels.condition=\"Ready\" AND metric.labels.status!=\"True\""
        aligner     = "ALIGN_COUNT_TRUE"
        period      = "60s"
        comparison  = "COMPARISON_GT"
        threshold   = 0
        duration    = "300s"
      }
      "gke-container-restarts" = {
        description = "A container restarted more than 3 times in 10 minutes (crash loop)."
        filter      = "metric.type=\"kubernetes.io/container/restart_count\" AND resource.type=\"k8s_container\""
        aligner     = "ALIGN_DELTA"
        period      = "600s"
        comparison  = "COMPARISON_GT"
        threshold   = 3
        duration    = "0s"
      }
      "sql-cpu-high" = {
        description = "Cloud SQL CPU above 80% for 10 minutes."
        filter      = "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\" AND resource.type=\"cloudsql_database\""
        aligner     = "ALIGN_MEAN"
        period      = "60s"
        comparison  = "COMPARISON_GT"
        threshold   = 0.8
        duration    = "600s"
      }
      "sql-disk-high" = {
        description = "Cloud SQL disk above 85% full."
        filter      = "metric.type=\"cloudsql.googleapis.com/database/disk/utilization\" AND resource.type=\"cloudsql_database\""
        aligner     = "ALIGN_MEAN"
        period      = "60s"
        comparison  = "COMPARISON_GT"
        threshold   = 0.85
        duration    = "300s"
      }
      "sql-replication-lag" = {
        description = "Cloud SQL replica more than 60 seconds behind. Silent while the cross-region replica is off."
        filter      = "metric.type=\"cloudsql.googleapis.com/database/replication/replica_lag\" AND resource.type=\"cloudsql_database\""
        aligner     = "ALIGN_MEAN"
        period      = "60s"
        comparison  = "COMPARISON_GT"
        threshold   = 60
        duration    = "300s"
      }
      "sql-instance-down" = {
        description = "The Cloud SQL primary reports not up for 3 minutes. Triggers the failover runbook (incident/) when enabled."
        filter      = "metric.type=\"cloudsql.googleapis.com/database/up\" AND resource.type=\"cloudsql_database\""
        aligner     = "ALIGN_MEAN"
        period      = "60s"
        comparison  = "COMPARISON_LT"
        threshold   = 1
        duration    = "180s"
      }
      "sql-failover" = {
        description = "A Cloud SQL failover operation ran."
        filter      = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.sql_failover.name}\" AND resource.type=\"cloudsql_database\""
        aligner     = "ALIGN_SUM"
        period      = "60s"
        comparison  = "COMPARISON_GT"
        threshold   = 0
        duration    = "0s"
      }
      "nat-port-exhaustion" = {
        description = "Cloud NAT dropped packets for lack of ports or addresses."
        filter      = "metric.type=\"router.googleapis.com/nat/dropped_sent_packets_count\" AND resource.type=\"nat_gateway\" AND metric.labels.reason=\"OUT_OF_RESOURCES\""
        aligner     = "ALIGN_SUM"
        period      = "60s"
        comparison  = "COMPARISON_GT"
        threshold   = 0
        duration    = "0s"
      }
      "nat-allocation-failed" = {
        description = "Cloud NAT could not allocate a port for a connection."
        filter      = "metric.type=\"router.googleapis.com/nat/nat_allocation_failed\" AND resource.type=\"nat_gateway\""
        aligner     = "ALIGN_COUNT_TRUE"
        period      = "60s"
        comparison  = "COMPARISON_GT"
        threshold   = 0
        duration    = "0s"
      }
      "ngfw-egress-deny-spike" = {
        description = "More than ${var.egress_deny_threshold} denied egress connections in 5 minutes on the restricted host project."
        filter      = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.ngfw_egress_deny.name}\" AND resource.type=\"gce_subnetwork\""
        aligner     = "ALIGN_SUM"
        period      = "300s"
        comparison  = "COMPARISON_GT"
        threshold   = var.egress_deny_threshold
        duration    = "0s"
      }
    },
    var.enable_incident_channel ? {
      "stale-secret" = {
        description = "A secret's newest enabled version is older than the limit (daily age check in incident/)."
        filter      = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.stale_secret[0].name}\" AND resource.type=\"cloud_run_revision\""
        aligner     = "ALIGN_SUM"
        period      = "300s"
        comparison  = "COMPARISON_GT"
        threshold   = 0
        duration    = "0s"
      }
    } : {},
    var.enable_mgmt_vm_alerts ? {
      "mgmt-vm-patch-failure" = {
        description = "OS Config logged an error on the management VM (patch job or agent failure)."
        filter      = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.patch_failure[0].name}\" AND resource.type=\"gce_instance\""
        aligner     = "ALIGN_SUM"
        period      = "300s"
        comparison  = "COMPARISON_GT"
        threshold   = 0
        duration    = "0s"
      }
    } : {},
  )
}

resource "google_monitoring_alert_policy" "threshold" {
  for_each = local.threshold_alerts

  project      = local.logging_project
  display_name = "lz-ops-${each.key}"
  combiner     = "OR"

  conditions {
    display_name = each.value.description

    condition_threshold {
      filter          = each.value.filter
      comparison      = each.value.comparison
      threshold_value = each.value.threshold
      duration        = each.value.duration

      aggregations {
        alignment_period   = each.value.period
        per_series_aligner = each.value.aligner
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = concat(
    google_monitoring_notification_channel.ops[*].id,
    contains(local.incident_policies, each.key) ? google_monitoring_notification_channel.incident[*].id : [],
  )

  documentation {
    content   = each.value.description
    mime_type = "text/markdown"
  }

  depends_on = [google_monitoring_monitored_project.scope]
}

# ---- management VM uptime ----------------------------------------------------

resource "google_monitoring_alert_policy" "mgmt_uptime" {
  for_each = var.enable_mgmt_vm_alerts ? { "mgmt-vm-down" = var.mgmt_vm_name } : {}

  project      = local.logging_project
  display_name = "lz-ops-${each.key}"
  combiner     = "OR"

  conditions {
    display_name = "No uptime reported by ${each.value} for 10 minutes."

    condition_absent {
      filter   = "metric.type=\"compute.googleapis.com/instance/uptime\" AND resource.type=\"gce_instance\" AND metadata.system_labels.name=\"${each.value}\""
      duration = "600s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = google_monitoring_notification_channel.ops[*].id

  documentation {
    content   = "The management VM stopped reporting uptime. Expected during a teardown, which is why this policy is destroyed first."
    mime_type = "text/markdown"
  }

  depends_on = [google_monitoring_monitored_project.scope]
}
