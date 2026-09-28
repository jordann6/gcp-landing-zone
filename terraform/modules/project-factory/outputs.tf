# Both IDs wait on the API enables: a caller that creates a KMS key ring or
# reads the BigQuery service account in this project otherwise races the enable
# and fails with SERVICE_DISABLED on the first apply.
output "project_id" {
  description = "Generated project ID."
  value       = google_project.this.project_id
  depends_on  = [google_project_service.this]
}

output "project_number" {
  description = "Generated project number."
  value       = google_project.this.number
  depends_on  = [google_project_service.this]
}

output "name" {
  description = "Short name the project was vended under."
  value       = var.name
}
