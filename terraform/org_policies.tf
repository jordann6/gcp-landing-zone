# Org policy: the preventive layer.
#
# This is GCP's answer to AWS SCPs and Azure Policy, and it differs from both in
# a way worth being precise about. An SCP is a deny boundary evaluated at
# request time against IAM. Azure Policy can deny, audit, or mutate through
# effects. GCP org policy constrains the *shape of the configuration itself*:
# the API rejects a resource that violates a constraint, so the violation cannot
# exist rather than merely being disallowed to whoever asked.
#
# Org-wide constraints attach at the organization so a project created outside
# the landing zone folders is still governed. A policy attached only to a folder
# is bypassed by creating a project somewhere else. Folder-level policy is used
# only where the point is that one tier differs from another (prod CMEK, the
# sandbox location widening).

locals {
  # Google pre-applies a secure-by-default set on new organizations. These are
  # NOT managed here, deliberately. The v1 build imported them to resolve 409s,
  # which made Terraform their owner, and `terraform destroy` then deleted them,
  # leaving the org less protected than before the landing zone existed.
  # Leaving them unmanaged means destroy cannot touch them. scripts/test-guardrails.sh
  # asserts they are still enforced, so the landing zone still depends on them
  # being there without owning them.
  google_default_constraints = [
    "compute.restrictProtocolForwardingCreationForTypes",
    "compute.setNewProjectDefaultToZonalDNSOnly",
    "iam.automaticIamGrantsForDefaultServiceAccounts",
    "iam.disableServiceAccountKeyCreation",
    "iam.disableServiceAccountKeyUpload",
    "storage.uniformBucketLevelAccess",
  ]

  # Boolean constraints this landing zone owns, enforced everywhere.
  boolean_constraints = [
    # No default VPC, with its permissive rules nobody chose.
    "compute.skipDefaultNetworkCreation",

    # Serial console access bypasses SSH controls and OS Login entirely.
    "compute.disableSerialPortAccess",

    # SSH keys managed by IAM rather than by metadata, so access is revoked by
    # removing a role instead of hunting down a key.
    "compute.requireOsLogin",

    # Secure boot, vTPM, and integrity monitoring on every VM, GKE nodes included.
    "compute.requireShieldedVm",

    # Guest attributes leak instance metadata written from inside the VM, and
    # nested virtualization runs a hypervisor the platform cannot see into.
    "compute.disableGuestAttributesAccess",
    "compute.disableNestedVirtualization",

    # A Shared VPC host cannot have its lien removed, so a host project cannot be
    # deleted out from under the service projects that depend on it.
    "compute.restrictXpnProjectLienRemoval",

    # Cloud SQL stays off public IPs, and authorized networks cannot be added to
    # open a path around that.
    "sql.restrictPublicIp",
    "sql.restrictAuthorizedNetworks",

    # Public access prevention on every bucket, not only the ones someone
    # remembered to configure.
    "storage.publicAccessPrevention",
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
# could still allow specific instances.
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

# ---- tier-specific policy -------------------------------------------------------

# Sandbox widens one inherited constraint, deliberately, to demonstrate the
# mechanism. inherit_from_parent = false with a wider value set is how an
# exception is granted without disabling the parent policy, and it is the part
# of GCP org policy that has no clean SCP analogue: an SCP deny cannot be
# un-denied lower down, so AWS grants exceptions by moving the account.
resource "google_org_policy_policy" "sandbox_locations" {
  name   = "${google_folder.sandbox.name}/policies/gcp.resourceLocations"
  parent = google_folder.sandbox.name

  spec {
    inherit_from_parent = false

    rules {
      values {
        allowed_values = concat(var.allowed_resource_locations, var.sandbox_extra_locations)
      }
    }
  }
}

# Prod is stricter by placement alone. The listed services cannot create a
# resource in the prod folder without a customer-managed key, so the workload
# root's CMEK wiring is enforced by the platform, not by review. Dev and test
# carry no such rule, which is the point: the same Terraform would be accepted
# there and rejected here.
resource "google_org_policy_policy" "prod_require_cmek" {
  name   = "${google_folder.env["prod"].name}/policies/gcp.restrictNonCmekServices"
  parent = google_folder.env["prod"].name

  spec {
    rules {
      values {
        denied_values = var.prod_cmek_services
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
