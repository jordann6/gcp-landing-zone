output "repository" {
  description = "Repository scripts/build-run-image.sh rotation pushes to (the workload's CMEK apps repo)."
  value       = local.wl.apps_repository
}

output "service_account" {
  value = google_service_account.rotator.email
}

output "rotator" {
  description = "Deployed service, or null before the image exists."
  value = local.deploy ? {
    name         = google_cloud_run_v2_service.rotator[0].name
    uri          = google_cloud_run_v2_service.rotator[0].uri
    project      = local.project
    region       = var.region
    subscription = google_pubsub_subscription.rotator[0].name
    secret       = local.secret
  } : null
}
