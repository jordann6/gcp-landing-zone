terraform {
  required_version = ">= 1.9"

  backend "gcs" {}

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

# billing_project plus user_project_override is required when applying with user
# credentials. Without it, APIs that demand a quota project (orgpolicy and
# serviceusage among them) bill the call to Google's shared OAuth client project
# and fail with SERVICE_DISABLED on a project ID you do not recognize.
provider "google" {
  region                = var.region
  billing_project       = var.seed_project_id
  user_project_override = true
}
