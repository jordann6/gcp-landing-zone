terraform {
  required_version = ">= 1.9"

  # The bucket is written out, not passed from backend.hcl, because CI inits
  # this root with no backend config. The prefix must match ci_state_prefix in
  # bootstrap/wif.tf: it is the only state sa-gha-apply may write. A re-run of
  # make bootstrap mints a new seed suffix; update the bucket here to match.
  backend "gcs" {
    bucket = "jn-lz-seed-8890bf-tfstate"
    prefix = "landing-zone/ci-proof"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.50"
    }
  }
}

# No impersonate_service_account: in CI the job already is the identity it
# needs (sa-gha-plan for the plan, sa-gha-apply after the reviewer approves).
# The project comes from google-github-actions/auth, which exports the service
# account's own project, the seed.
provider "google" {
  region = var.region
  # Inline literals, not a variable: the policy gate reads provider
  # default_labels statically, and a variable reference is opaque to it.
  default_labels = {
    project     = "gcp-landing-zone"
    owner       = "jordan"
    managed-by  = "terraform"
    cost_center = "cc-0001"
  }
}
