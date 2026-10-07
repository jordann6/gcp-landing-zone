terraform {
  required_version = ">= 1.9"

  # Its own state. The image root holds what the bake and the patch runs read
  # from (the Ubuntu mirror, the bake network), so it outlives a rebake and is
  # destroyed with the session, after compute/ and before governance.
  backend "gcs" {
    prefix = "landing-zone/image"
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

data "terraform_remote_state" "governance" {
  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "landing-zone/governance"
    impersonate_service_account = var.terraform_service_account
  }
}
