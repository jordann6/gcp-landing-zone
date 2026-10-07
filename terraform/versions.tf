terraform {
  required_version = ">= 1.9"

  # bucket and impersonate_service_account come from backend.hcl (bootstrap
  # output backend_hcl). The prefix is fixed per root so the three roots can
  # never share a state file by accident.
  backend "gcs" {
    prefix = "landing-zone/governance"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.50"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.50"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# Applies as sa-terraform, never as the operator. The operator's own credentials
# only mint a short-lived token for the service account, which is the single
# standing human grant in the landing zone (bootstrap/identity.tf).
#
# billing_project + user_project_override bill every call to the seed project.
# Without it, org-scoped APIs (orgpolicy, accesscontextmanager, PAM) have no
# quota project and fail with SERVICE_DISABLED on a project ID you do not own.
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

# google-beta only for google_project_service_identity, which forces the Cloud
# Asset service agent to exist before the feed topic and the export dataset name
# it in a grant. The agent is created lazily, and a grant to one that does not
# exist yet fails the apply.
provider "google-beta" {
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
