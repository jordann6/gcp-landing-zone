# Consumed by network/ and workload/ through terraform_remote_state, so the
# shapes here are the contract between roots. Change them in all three.

output "org_id" {
  description = "Organization the landing zone governs."
  value       = var.org_id
}

output "folders" {
  description = "Hierarchy the landing zone created (folders/<id>)."
  value       = local.folder_ids
}

output "logging_project_id" {
  description = "Project holding the org audit dataset, log bucket, telemetry key, and alerting."
  value       = module.logging_project.project_id
}

output "hub_project_id" {
  description = "Core network hub project, or null when not vended."
  value       = one(module.hub_project[*].project_id)
}

output "sandbox_project_id" {
  description = "Sandbox project, or null when not vended."
  value       = one(module.sandbox_project[*].project_id)
}

output "host_projects" {
  description = "Shared VPC host projects by key (net-<env> base, net-<env>-r restricted)."
  value = {
    for k, h in local.hosts : k => {
      project_id = module.host[k].project_id
      number     = module.host[k].project_number
      env        = h.env
      restricted = h.restricted
    }
  }
}

output "app_projects" {
  description = "Service projects by key (app-<env>) and the host each one attaches to."
  value = {
    for k, a in local.apps : k => {
      project_id = module.app[k].project_id
      number     = module.app[k].project_number
      env        = a.env
      host       = a.host
    }
  }
}

output "workforce_pool" {
  description = "Workforce pool resource name. Persona principalSets are built from it."
  value       = google_iam_workforce_pool.lz.name
}

output "persona_principals" {
  description = "principalSet URI per persona."
  value       = local.persona_principal
}

output "audit_dataset" {
  description = "BigQuery dataset receiving organization audit logs."
  value       = "${module.logging_project.project_id}.${google_bigquery_dataset.audit.dataset_id}"
}

output "sink_writer_identity" {
  description = "Service account the BigQuery org sink writes as. Granting this is the step most often missed."
  value       = google_logging_organization_sink.audit.writer_identity
}

output "sink_writer_identities" {
  description = "Writer identities of both org sinks. The VPC-SC perimeter needs an egress rule for them, or logs from inside it stop arriving."
  value = [
    google_logging_organization_sink.audit.writer_identity,
    google_logging_organization_sink.bucket.writer_identity,
  ]
}

output "logging_project_number" {
  description = "Logging project number, for VPC-SC egress targets."
  value       = module.logging_project.project_number
}

output "enforced_constraints" {
  description = "Org policy constraints this landing zone enforces organization-wide."
  value = concat(
    local.boolean_constraints,
    ["compute.vmExternalIpAccess", "gcp.resourceLocations"],
    [for c in google_org_policy_custom_constraint.this : c.name],
  )
}

output "google_default_constraints" {
  description = "Constraints Google pre-applied that this landing zone relies on but deliberately does not manage."
  value       = local.google_default_constraints
}

output "findings_topic" {
  description = "Pub/Sub topic receiving Security Command Center findings."
  value       = google_pubsub_topic.findings.id
}
