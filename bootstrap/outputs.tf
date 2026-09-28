output "seed_project_id" {
  description = "Project holding Terraform state for the landing zone."
  value       = google_project.seed.project_id
}

output "state_bucket" {
  description = "Terraform state bucket."
  value       = google_storage_bucket.state.name
}

output "backend_hcl" {
  description = "Paste into terraform/backend.hcl, then: terraform init -backend-config=backend.hcl"
  value       = <<-EOT
    bucket                      = "${google_storage_bucket.state.name}"
    impersonate_service_account = "${google_service_account.terraform.email}"
  EOT
}

output "tfvars_snippet" {
  description = "Values the root module needs."
  value       = <<-EOT
    seed_project_id           = "${google_project.seed.project_id}"
    terraform_service_account = "${google_service_account.terraform.email}"
  EOT
}

output "terraform_service_account" {
  description = "Identity every root applies as, through impersonation."
  value       = google_service_account.terraform.email
}

output "github_workload_identity_provider" {
  description = "Pass as gcp_workload_identity_provider to the platform-guardrails workflows."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "github_plan_service_account" {
  description = "Read-only CI identity (gcp_service_account / gcp_plan_service_account)."
  value       = google_service_account.gha_plan.email
}
