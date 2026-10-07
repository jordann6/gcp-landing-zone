variable "seed_project_id" {
  description = "Seed project (bootstrap output). Quota project for every call."
  type        = string
}

variable "terraform_service_account" {
  description = "sa-terraform email (bootstrap output). This root applies as it."
  type        = string
}

variable "state_bucket" {
  description = "State bucket (bootstrap output), read for the other roots' outputs."
  type        = string
}

variable "env" {
  description = "Environment whose app project and restricted subnet the VM lands in."
  type        = string
  default     = "prod"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "machine_type" {
  description = "Smallest size that boots the image. The VM is hourly and destroyed with the session."
  type        = string
  default     = "e2-micro"
}

variable "image_family" {
  description = "Golden image family in the image project."
  type        = string
  default     = "hardened-ubuntu-2204"
}

variable "operators" {
  description = <<-EOT
    Principals who run make test-compute: IAP tunnel, OS Login with sudo,
    compute read, and patch job execution on the VM's project.
    user:you@example.com form.
  EOT
  type        = list(string)
  default     = []
}

variable "patch_window" {
  description = "Weekly patch run (UTC): day of week and hour."
  type = object({
    day  = string
    hour = number
  })
  default = {
    day  = "SUNDAY"
    hour = 7
  }
}
