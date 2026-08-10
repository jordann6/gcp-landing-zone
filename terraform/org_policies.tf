# Org policy: the preventive layer.
#
# This is GCP's answer to AWS SCPs and Azure Policy, and it differs from both in
# a way worth being precise about. An SCP is a deny boundary evaluated at
# request time against IAM. Azure Policy can deny, audit, or mutate through
# effects. GCP org policy constrains the *shape of the configuration itself*:
# the API rejects a resource that violates a constraint, so the violation cannot
# exist rather than merely being disallowed to whoever asked.
#
# Everything here is applied at the organization so a project created outside
# the landing zone folders is still governed. A policy attached only to a folder
# is bypassed by creating a project somewhere else, which defeats the point.

locals {
  # Boolean constraints enforced everywhere, no exceptions.
  boolean_constraints = [
    # No service account keys. Same control as the federation build, hoisted to
    # the altitude it belongs at once more than one project exists.
    "iam.disableServiceAccountKeyCreation",
    "iam.disableServiceAccountKeyUpload",

    # No default VPC, with its permissive rules nobody chose.
    "compute.skipDefaultNetworkCreation",

    # Serial console access bypasses SSH controls and OS Login entirely.
    "compute.disableSerialPortAccess",

    # SSH keys managed by IAM rather than by metadata, so access is revoked by
    # removing a role instead of hunting down a key.
    "compute.requireOsLogin",

    # Cloud SQL instances stay off public IPs.
    "sql.restrictPublicIp",

    # ACLs are legacy and reason about objects individually. Uniform access
    # means bucket IAM is the whole story.
    "storage.uniformBucketLevelAccess",
  ]
}

resource "google_org_policy_policy" "boolean" {
  for_each = toset(local.boolean_constraints)

  name   = "organizations/${var.org_id}/policies/${each.value}"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      enforce = "TRUE"
    }
  }
}

# No external IPs on VMs. A list constraint denying all values, which is not the
# same as a boolean: it is a deny of every possible value, and a child folder
# can still allow specific ones.
resource "google_org_policy_policy" "vm_external_ip" {
  name   = "organizations/${var.org_id}/policies/compute.vmExternalIpAccess"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      deny_all = "TRUE"
    }
  }
}

# Data residency. Restricts where resources can be created at all, which is the
# control that answers a compliance question rather than a cost one.
resource "google_org_policy_policy" "resource_locations" {
  name   = "organizations/${var.org_id}/policies/gcp.resourceLocations"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      values {
        allowed_values = var.allowed_resource_locations
      }
    }
  }
}

# Inheritance override, built deliberately to demonstrate the mechanism.
#
# nonprod inherits every constraint above, then relaxes exactly one: resource
# locations widen to include EU value groups for a residency test. inherit_from_parent
# with a narrower rule is how an exception is granted without disabling the
# parent policy, and it is the part of GCP org policy that has no clean SCP
# analogue, since an SCP deny cannot be un-denied lower down.
resource "google_org_policy_policy" "nonprod_locations" {
  name   = "${google_folder.nonprod.name}/policies/gcp.resourceLocations"
  parent = google_folder.nonprod.name

  spec {
    inherit_from_parent = false

    rules {
      values {
        allowed_values = concat(var.allowed_resource_locations, var.nonprod_extra_locations)
      }
    }
  }
}

# Domain restricted sharing. Off by default, and the default is the interesting
# part: this constraint blocks binding allUsers or allAuthenticatedUsers, which
# breaks any public Cloud Run service. Enabling it without knowing that is how a
# landing zone quietly blocks a workload the org intends to run.
resource "google_org_policy_policy" "domain_restricted_sharing" {
  count = var.enable_domain_restricted_sharing ? 1 : 0

  name   = "organizations/${var.org_id}/policies/iam.allowedPolicyMemberDomains"
  parent = "organizations/${var.org_id}"

  spec {
    rules {
      values {
        allowed_values = ["is:${var.customer_id}"]
      }
    }
  }
}
