variable "seed_project_id" {
  description = "Seed project (bootstrap output). Quota project for every call."
  type        = string
}

variable "terraform_service_account" {
  description = "sa-terraform email (bootstrap output). This root applies as it."
  type        = string
}

variable "state_bucket" {
  description = "State bucket (bootstrap output), read for the governance root's outputs."
  type        = string
}

variable "region" {
  description = "Region for the bake subnet and the Artifact Registry mirror."
  type        = string
  default     = "us-central1"
}

variable "operators" {
  description = <<-EOT
    Principals who run make build-image. Their one grant is token creation on
    sa-image-builder, which Packer impersonates to create the bake VM, reach it
    over IAP with OS Login, and publish the image. Destroyed with this root.
    user:you@example.com form.
  EOT
  type        = list(string)
  default     = []
}

variable "ubuntu_suites" {
  description = <<-EOT
    Ubuntu suites mirrored through Artifact Registry remote repositories, one
    repository per suite (the remote path is ubuntu/dists/<suite>). The
    security pocket is listed on purpose: a mirror without it bakes and patches
    from release-day packages.
  EOT
  type        = list(string)
  default     = ["jammy", "jammy-updates", "jammy-security"]
}
