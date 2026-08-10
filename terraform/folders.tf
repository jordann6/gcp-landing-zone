# Resource hierarchy.
#
# The hierarchy is the policy surface. On GCP, org policy and IAM both inherit
# downward, so where a project sits decides what governs it. That makes folder
# design a security decision rather than an organizational preference, and it is
# the sharpest structural difference from AWS, where an SCP attaches to an OU
# but IAM does not inherit the same way.
#
#   organization
#   ├── core          platform-owned, stricter, not developer-facing
#   │     ├── logging          (org log sink destination)
#   │     └── network          (Shared VPC host)
#   └── workloads     application projects, split by environment
#         ├── nonprod         (one relaxed constraint, deliberately)
#         └── prod

resource "google_folder" "core" {
  display_name        = "core"
  parent              = "organizations/${var.org_id}"
  deletion_protection = false
}

resource "google_folder" "workloads" {
  display_name        = "workloads"
  parent              = "organizations/${var.org_id}"
  deletion_protection = false
}

resource "google_folder" "nonprod" {
  display_name        = "nonprod"
  parent              = google_folder.workloads.name
  deletion_protection = false
}

resource "google_folder" "prod" {
  display_name        = "prod"
  parent              = google_folder.workloads.name
  deletion_protection = false
}
