output "repository" {
  description = "Repository scripts/build-run-image.sh slo pushes to (the workload's CMEK apps repo)."
  value       = local.wl.apps_repository
}

output "service" {
  description = "Deployed service and its SLO, or null before the image exists."
  value = local.deploy ? {
    name     = google_cloud_run_v2_service.orders[0].name
    uri      = google_cloud_run_v2_service.orders[0].uri
    project  = local.project
    region   = var.region
    slo      = google_monitoring_slo.availability[0].id
    policies = { for k, p in google_monitoring_alert_policy.burn : k => p.display_name }
  } : null
}
