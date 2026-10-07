output "ops_topic" {
  description = "Topic the Monitoring Pub/Sub channel (observability/) publishes to."
  value       = google_pubsub_topic.ops_alerts.id
}

output "repository" {
  description = "Image repository for scripts/build-incident.sh."
  value       = "${var.region}-docker.pkg.dev/${local.logging_project}/${google_artifact_registry_repository.incident.repository_id}"
}

output "service_account" {
  value = google_service_account.incident.email
}

output "handler" {
  description = "Deployed service, or null before the image exists."
  value = local.deploy ? {
    name          = google_cloud_run_v2_service.incident[0].name
    uri           = google_cloud_run_v2_service.incident[0].uri
    project       = local.logging_project
    region        = var.region
    dry_run       = var.dry_run
    scc_sub       = google_pubsub_subscription.incident["scc"].name
    ops_sub       = google_pubsub_subscription.incident["ops"].name
    scc_topic     = local.gov.findings_topic
    age_proof_job = google_cloud_scheduler_job.secret_age["proof"].name
  } : null
}

output "quarantine_tag_value" {
  value = local.tag_value
}
