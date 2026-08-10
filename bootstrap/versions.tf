terraform {
  required_version = ">= 1.9"

  # Local state on purpose: this layer creates the bucket every other layer
  # stores state in. The state file is gitignored.
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

provider "google" {}
