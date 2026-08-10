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

variable "shared_vpc_host_project" {
  description = "Host project to attach to as a service project. Empty means do not attach."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Labels applied to the project."
  type        = map(string)
  default     = {}
}
