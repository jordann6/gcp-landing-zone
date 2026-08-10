variable "name" {
  description = "Short project name. Combined with name_prefix and a random suffix to form the project ID."
  type        = string
}

variable "name_prefix" {
  description = "Prefix shared by every project in the landing zone."
  type        = string
}

variable "folder_id" {
  description = "Folder the project is created in. Placement decides which org policies apply, so this is not cosmetic."
  type        = string
}

variable "billing_account" {
  description = "Billing account to link."
  type        = string
}

variable "environment" {
  description = "Environment label applied to the project."
  type        = string
  default     = "shared"
}

variable "apis" {
  description = "APIs to enable on the project."
  type        = list(string)
  default     = ["cloudresourcemanager.googleapis.com", "serviceusage.googleapis.com"]
}

variable "audit_log_types" {
  description = "Audit log types to enable across all services."
  type        = list(string)
  default     = ["ADMIN_READ", "DATA_READ", "DATA_WRITE"]
}

variable "attach_shared_vpc" {
  description = <<-EOT
    Attach this project to the Shared VPC host as a service project.

    A separate flag rather than inferring intent from shared_vpc_host_project
    being non-empty. The host project ID is generated in the same apply, so it
    is unknown at plan time, and a count that depends on an unknown value fails
    with "The count value depends on resource attributes that cannot be
    determined until apply". Resource *count* must be knowable at plan time even
    when the resource's arguments are not.
  EOT
  type        = bool
  default     = false
}

variable "shared_vpc_host_project" {
  description = "Host project to attach to. Only read when attach_shared_vpc is true."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Labels applied to the project."
  type        = map(string)
  default     = {}
}
