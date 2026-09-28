output "project_id" {
  description = "Prod app project the paved road landed in."
  value       = local.project
}

output "cluster" {
  description = "GKE cluster name, zone, and DNS endpoint (the operator access path)."
  value = {
    name         = google_container_cluster.paved_road.name
    location     = google_container_cluster.paved_road.location
    dns_endpoint = try(google_container_cluster.paved_road.control_plane_endpoints_config[0].dns_endpoint_config[0].endpoint, null)
  }
}

output "get_credentials" {
  description = "kubectl access through the DNS endpoint. No IP allowlist, no bastion; IAM decides."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.paved_road.name} --zone ${var.zone} --project ${local.project} --dns-endpoint"
}

output "sql" {
  description = "Cloud SQL primary and DR replica."
  value = {
    primary            = google_sql_database_instance.primary.name
    connection_name    = google_sql_database_instance.primary.connection_name
    private_ip         = google_sql_database_instance.primary.private_ip_address
    replica            = one(google_sql_database_instance.replica[*].name)
    replica_private_ip = one(google_sql_database_instance.replica[*].private_ip_address)
  }
}

output "registry" {
  description = "The one image URL prefix workloads use (virtual repo over org images and the Docker Hub cache)."
  value       = "${var.region}-docker.pkg.dev/${local.project}/${google_artifact_registry_repository.docker.repository_id}"
}

output "attestor" {
  description = "Binary Authorization attestor and its KMS signing key version."
  value = {
    attestor    = google_binary_authorization_attestor.approved.id
    key_version = data.google_kms_crypto_key_version.attestor.id
  }
}

output "db_secret" {
  description = "Secret Manager secret holding the app DB password."
  value       = google_secret_manager_secret.db_password.id
}

output "backup_vault" {
  description = "Backup vault, or null."
  value       = one(google_backup_dr_backup_vault.sql[*].id)
}
