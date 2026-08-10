output "project_id" {
  description = "Generated project ID."
  value       = google_project.this.project_id
}

output "project_number" {
  description = "Generated project number."
  value       = google_project.this.number
}

output "name" {
  description = "Short name the project was vended under."
  value       = var.name
}
