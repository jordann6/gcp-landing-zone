# Firewall: hierarchical policy at the org, network policy per VPC.
#
# This is where the GCP zone deliberately differs from AWS in shape while
# matching it in intent. AWS centralizes inspection: every VPC routes through an
# egress VPC with Network Firewall in it. On GCP the equivalent control is
# distributed. Cloud NGFW enforces firewall policy in the fabric at every VM
# NIC, so there is no appliance to route through and nothing to scale or fail
# over. Building an AWS-style hub with NVAs here would add cost and a choke
# point to reproduce something the platform already does natively.
#
#   Org hierarchical policy    applies to every VPC in the org, including ones
#                              this landing zone did not create. Denies internet
#                              ingress, admits IAP and health checks, and drops
#                              traffic to known-malicious IPs in both directions.
#   Network policy per VPC     default-deny egress with an FQDN allowlist
#                              (Cloud NGFW Standard), so the only internet a
#                              workload can reach is what is named here.

locals {
  org_id = local.gov.org_id

  # Google-published ranges.
  iap_range           = "35.235.240.0/20"
  health_check_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
}

resource "google_compute_firewall_policy" "org" {
  parent      = "organizations/${local.org_id}"
  short_name  = "lz-org-baseline"
  description = "Org-wide baseline: no internet ingress except IAP and health checks; threat-intel deny both ways."
}

resource "google_compute_firewall_policy_association" "org" {
  name              = "lz-org-baseline"
  firewall_policy   = google_compute_firewall_policy.org.id
  attachment_target = "organizations/${local.org_id}"
}

locals {
  org_rules = {
    # Known-bad destinations and sources, from Google Threat Intelligence. The
    # GCP counterpart of Azure Firewall threat_intel_mode = Deny.
    deny-threat-intel-egress = {
      priority = 100, direction = "EGRESS", action = "deny"
      match    = { dest_threat_intelligences = ["iplist-known-malicious-ips"] }
      l4       = [{ ip_protocol = "all", ports = [] }]
    }
    deny-threat-intel-ingress = {
      priority = 110, direction = "INGRESS", action = "deny"
      match    = { src_threat_intelligences = ["iplist-known-malicious-ips"] }
      l4       = [{ ip_protocol = "all", ports = [] }]
    }

    # SSH only through IAP, where every session is authenticated and logged.
    allow-iap-ssh = {
      priority = 1000, direction = "INGRESS", action = "allow"
      match    = { src_ip_ranges = [local.iap_range] }
      l4       = [{ ip_protocol = "tcp", ports = ["22"] }]
    }
    allow-health-checks = {
      priority = 1100, direction = "INGRESS", action = "allow"
      match    = { src_ip_ranges = local.health_check_ranges }
      l4       = [{ ip_protocol = "tcp", ports = [] }]
    }

    # Internal traffic is not decided here. goto_next hands it to the VPC's own
    # rules, so segmentation stays with the network that owns the workload.
    internal-to-vpc = {
      priority = 2000, direction = "INGRESS", action = "goto_next"
      match    = { src_ip_ranges = ["10.0.0.0/8"] }
      l4       = [{ ip_protocol = "all", ports = [] }]
    }

    # Everything else from the internet stops at the org, for every VPC that
    # exists or ever will.
    deny-internet-ingress = {
      priority = 65000, direction = "INGRESS", action = "deny"
      match    = { src_ip_ranges = ["0.0.0.0/0"] }
      l4       = [{ ip_protocol = "all", ports = [] }]
    }
  }
}

resource "google_compute_firewall_policy_rule" "org" {
  for_each = local.org_rules

  firewall_policy = google_compute_firewall_policy.org.name
  description     = each.key
  priority        = each.value.priority
  direction       = each.value.direction
  action          = each.value.action
  enable_logging  = each.value.action != "goto_next"

  match {
    src_ip_ranges             = lookup(each.value.match, "src_ip_ranges", null)
    dest_ip_ranges            = each.value.direction == "EGRESS" && lookup(each.value.match, "dest_threat_intelligences", null) == null ? ["0.0.0.0/0"] : null
    src_threat_intelligences  = lookup(each.value.match, "src_threat_intelligences", null)
    dest_threat_intelligences = lookup(each.value.match, "dest_threat_intelligences", null)

    dynamic "layer4_configs" {
      for_each = each.value.l4
      content {
        ip_protocol = layer4_configs.value.ip_protocol
        ports       = length(layer4_configs.value.ports) > 0 ? layer4_configs.value.ports : null
      }
    }
  }
}

# ---- per-VPC network firewall policy -------------------------------------------

resource "google_compute_network_firewall_policy" "vpc" {
  for_each = local.vpcs

  project     = each.value.project
  name        = "fwp-${each.value.env}-${each.value.restricted ? "restricted" : "base"}"
  description = "Default-deny egress with an FQDN allowlist for ${each.key}."
}

resource "google_compute_network_firewall_policy_association" "vpc" {
  for_each = local.vpcs

  project           = each.value.project
  name              = "fwp-${each.key}"
  firewall_policy   = google_compute_network_firewall_policy.vpc[each.key].name
  attachment_target = google_compute_network.vpc[each.key].id
}

# Ingress inside the VPC. Only the VPC's own range, which includes the GKE pod
# and service secondaries on the restricted tier, and the control plane range.
# Environments never share a VPC, so dev cannot reach prod even before this.
resource "google_compute_network_firewall_policy_rule" "allow_internal_ingress" {
  for_each = local.vpcs

  project         = each.value.project
  firewall_policy = google_compute_network_firewall_policy.vpc[each.key].name
  rule_name       = "allow-internal-ingress"
  priority        = 1000
  direction       = "INGRESS"
  action          = "allow"

  match {
    src_ip_ranges = [each.value.own_range, "10.${each.value.octet}.144.0/28"]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}

# Egress inside the VPC and to the PSC endpoint. The data-tier segmentation rules
# (only the app tier reaches the database port) are added by the workload root
# at a higher priority, because they name the workload's own identity.
resource "google_compute_network_firewall_policy_rule" "allow_internal_egress" {
  for_each = local.vpcs

  project         = each.value.project
  firewall_policy = google_compute_network_firewall_policy.vpc[each.key].name
  rule_name       = "allow-internal-egress"
  # Priorities are unique per policy across both directions, so this cannot
  # share 1000 with allow-internal-ingress.
  priority  = 1001
  direction = "EGRESS"
  action    = "allow"

  match {
    # own_range already contains the PSA range on the restricted tier.
    dest_ip_ranges = [each.value.own_range, "10.${each.value.octet}.144.0/28", "${each.value.psc_ip}/32"]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}

# The allowlist. Cloud NGFW Standard resolves each FQDN through Cloud DNS and
# keeps the address set current, so the rule tracks the destination, not a
# snapshot of its IPs.
resource "google_compute_network_firewall_policy_rule" "allow_fqdn_egress" {
  for_each = length(var.egress_fqdn_allowlist) > 0 ? local.vpcs : {}

  project         = each.value.project
  firewall_policy = google_compute_network_firewall_policy.vpc[each.key].name
  rule_name       = "allow-fqdn-egress"
  priority        = 2000
  direction       = "EGRESS"
  action          = "allow"
  enable_logging  = true

  match {
    dest_fqdns = var.egress_fqdn_allowlist
    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["443"]
    }
  }
}

resource "google_compute_network_firewall_policy_rule" "deny_egress" {
  for_each = local.vpcs

  project         = each.value.project
  firewall_policy = google_compute_network_firewall_policy.vpc[each.key].name
  rule_name       = "deny-all-egress"
  priority        = 65000
  direction       = "EGRESS"
  action          = "deny"
  enable_logging  = true

  match {
    dest_ip_ranges = ["0.0.0.0/0"]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}
