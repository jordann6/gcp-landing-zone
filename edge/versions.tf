terraform {
  required_version = ">= 1.9"

  # Its own state: the edge runs only for a session, after workload (the
  # cluster the Ingress lands in) and is destroyed before it, once
  # scripts/test-edge.sh --teardown has removed the Ingress.
  backend "gcs" {
    prefix = "landing-zone/edge"
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

data "terraform_remote_state" "workload" {
  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "landing-zone/workload"
    impersonate_service_account = var.terraform_service_account
  }
}
