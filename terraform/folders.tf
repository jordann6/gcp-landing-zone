# Resource hierarchy.
#
# The hierarchy is the policy surface. On GCP, org policy and IAM both inherit
# downward, so where a project sits decides what governs it. That makes folder
# design a security decision rather than an organizational preference, and it is
# the sharpest structural difference from AWS, where an SCP attaches to an OU
# but IAM does not inherit the same way.
#
# Five tiers, identical in name and intent to the AWS OUs and Azure management
# groups in the sibling landing zones:
#
#   organization
#   ├── core          platform-owned, not developer-facing
#   │     ├── logging          org sink destinations, telemetry CMEK, SCC + budget topics
#   │     └── net-hub          10.0/16: DNS inbound forwarding, hybrid placeholder
#   ├── workloads
#   │     ├── dev              net-dev (base host), app-dev
#   │     ├── test             net-test (base host), app-test
#   │     └── prod             net-prod (base host), net-prod-r (restricted host), app-prod
#   └── sandbox       one standalone project, its own VPC and budget
#
# The seed project (bootstrap/) sits outside all of it, on purpose: the thing
# that can rebuild the org does not live inside the part of the org it manages.

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

# Every environment gets its folder whether or not projects are vended into it.
# The folder is where the environment's policy lives, and an effective-policy
# query against an empty folder still proves the inheritance.
resource "google_folder" "env" {
  for_each = toset(["dev", "test", "prod"])

  display_name        = each.key
  parent              = google_folder.workloads.name
  deletion_protection = false
}

resource "google_folder" "sandbox" {
  display_name        = "sandbox"
  parent              = "organizations/${var.org_id}"
  deletion_protection = false
}
