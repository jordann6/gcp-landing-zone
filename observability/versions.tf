terraform {
  required_version = ">= 1.9"

  # Its own state: alerting deploys and destroys on its own, first in the
  # teardown order, so no alert fires for resources being removed.
  backend "gcs" {
    prefix = "landing-zone/observability"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.50"
    }
  }
}

provider "google" {
  region                      = var.region
  impersonate_service_account = var.terraform_service_account
  billing_project             = var.seed_project_id
  user_project_override       = true
  # Inline literals, not a variable: the policy gate reads provider
  # default_labels statically, and a variable reference is opaque to it.
  default_labels = {
    project     = "gcp-landing-zone"
    owner       = "jordan"
    managed-by  = "terraform"
    cost_center = "cc-0001"
  }
}
