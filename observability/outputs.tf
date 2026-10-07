output "metrics_scope" {
  description = "Scoping project and the projects it reads."
  value = {
    scoping_project = local.logging_project
    monitored       = local.monitored
  }
}

output "ops_channel" {
  description = "Ops notification channel resource name, or null when ops_alert_email is empty."
  value       = one(google_monitoring_notification_channel.ops[*].name)
}

output "alert_policies" {
  description = "Ops alert policy display names, for scripts/test-observability.sh."
  value = merge(
    { for k, p in google_monitoring_alert_policy.threshold : k => p.display_name },
    { for k, p in google_monitoring_alert_policy.mgmt_uptime : k => p.display_name },
  )
}
