terraform {
  required_version = ">= 1.9"

  # Its own state. The network root is the timed layer: NAT, PSC endpoints, and
  # the NGFW egress rules bill while they exist, so it deploys and destroys
  # independently of the governance root it reads from.
  backend "gcs" {
    prefix = "landing-zone/network"
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

# Everything this root builds on is an output of the governance root: folders,
# vended projects, the org ID. Read from state rather than passed by hand, so a
# re-vended project ID cannot drift out of sync with the network built for it.
data "terraform_remote_state" "governance" {
  backend = "gcs"
  config = {
    bucket                      = var.state_bucket
    prefix                      = "landing-zone/governance"
    impersonate_service_account = var.terraform_service_account
  }
}
