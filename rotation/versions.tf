terraform {
  required_version = ">= 1.9"

  # Its own state: the rotator runs only for a session, after workload (the
  # secret, topic, database and repo it acts on) and before it on destroy.
  backend "gcs" {
    prefix = "landing-zone/rotation"
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

data "terraform_remote_state" "network" {
  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "landing-zone/network"
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
