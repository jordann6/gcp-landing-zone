# Project factory.
#
# Every project in the landing zone is vended through this module, so no project
# can be created without a folder, a billing link, audit logging, and the
# default network suppressed. The value of a factory is not that it saves
# typing. It is that the baseline cannot be forgotten, because there is no code
# path that creates a project without it.

terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

resource "random_id" "suffix" {
  byte_length = 3
}

locals {
  project_id = "${var.name_prefix}-${var.name}-${random_id.suffix.hex}"
}

resource "google_project" "this" {
  name            = local.project_id
  project_id      = local.project_id
  folder_id       = var.folder_id
  billing_account = var.billing_account
  labels          = merge(var.labels, { environment = var.environment })

  deletion_policy = "DELETE"

  # Belt and braces. The org policy constraint also blocks default network
  # creation, but a project should not depend on a policy being present to be
  # built correctly.
  auto_create_network = false
}

resource "google_project_service" "this" {
  for_each = toset(var.apis)

  project            = google_project.this.project_id
  service            = each.value
  disable_on_destroy = false
}

# Data access logs are off by default across GCP. A landing zone that does not
# turn them on produces an audit trail that cannot answer who read what.
resource "google_project_iam_audit_config" "this" {
  project = google_project.this.project_id
  service = "allServices"

  dynamic "audit_log_config" {
    for_each = var.audit_log_types
    content {
      log_type = audit_log_config.value
    }
  }
}

# Attach to the Shared VPC host, when one is supplied. Service projects consume
# subnets from the host rather than owning networks, so network policy is set
# once and inherited rather than re-argued per project.
resource "google_compute_shared_vpc_service_project" "this" {
  count = var.shared_vpc_host_project == "" ? 0 : 1

  host_project    = var.shared_vpc_host_project
  service_project = google_project.this.project_id

  depends_on = [google_project_service.this]
}
