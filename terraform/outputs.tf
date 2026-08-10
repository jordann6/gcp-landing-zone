output "folders" {
  description = "Hierarchy the landing zone created."
  value = {
    core      = google_folder.core.name
    workloads = google_folder.workloads.name
    nonprod   = google_folder.nonprod.name
    prod      = google_folder.prod.name
  }
}

output "network_project_id" {
  description = "Shared VPC host project."
  value       = module.network_project.project_id
}

output "logging_project_id" {
  description = "Project holding the org audit log dataset."
  value       = module.logging_project.project_id
}

output "workload_projects" {
  description = "Projects vended through the factory, by environment."
  value = {
    nonprod = module.nonprod_app.project_id
    prod    = module.prod_app.project_id
  }
}

output "audit_dataset" {
  description = "BigQuery dataset receiving organization audit logs."
  value       = "${module.logging_project.project_id}.${google_bigquery_dataset.audit.dataset_id}"
}

output "sink_writer_identity" {
  description = "Service account the org sink writes as. Granting this is the step most often missed."
  value       = google_logging_organization_sink.audit.writer_identity
}

output "enforced_constraints" {
  description = "Org policy constraints enforced organization-wide."
  value       = concat(local.boolean_constraints, ["compute.vmExternalIpAccess", "gcp.resourceLocations"])
}

output "findings_topic" {
  description = "Pub/Sub topic receiving Security Command Center findings."
  value       = google_pubsub_topic.findings.id
}
