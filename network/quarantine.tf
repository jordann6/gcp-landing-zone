# Quarantine: the firewall half of the incident runbook (incident/).
#
# A VM that trips a SCC finding is isolated by binding a secure tag to it. This
# file owns the tag and the deny-all rules that target it; the incident handler
# only binds and unbinds. Defined here, not in incident/, because the rules live
# in the VPC firewall policy this root owns, and a quarantine rule must exist
# before anything can be quarantined.
#
# Secure tags, not legacy network tags: network firewall policy rules match
# secure tags and service accounts only. Legacy tags are a classic-firewall
# feature and no policy rule can target them.
#
# What it cuts: all egress and all internal ingress, ahead of the allow rules.
# What it does not: IAP SSH. The org policy (firewall.tf) allows 35.235.240.0/20
# to port 22 and an allow in the hierarchy is final, so an investigator can
# still reach a quarantined VM over IAP. That is deliberate: forensics needs a
# way in, and IAP is authenticated and logged.

resource "google_tags_tag_key" "quarantine" {
  for_each = local.restricted_vpcs

  parent      = "projects/${each.value.project}"
  short_name  = "lz-quarantine"
  description = "Binding this tag to a VM isolates it (deny-all in ${each.key}'s network firewall policy)."
  purpose     = "GCE_FIREWALL"

  purpose_data = {
    network = "${each.value.project}/${google_compute_network.vpc[each.key].name}"
  }
}

resource "google_tags_tag_value" "quarantine" {
  for_each = local.restricted_vpcs

  parent      = google_tags_tag_key.quarantine[each.key].id
  short_name  = "isolated"
  description = "VM is quarantined."
}

resource "google_compute_network_firewall_policy_rule" "quarantine_egress" {
  for_each = local.restricted_vpcs

  project         = each.value.project
  firewall_policy = google_compute_network_firewall_policy.vpc[each.key].name
  rule_name       = "quarantine-deny-egress"
  priority        = 100
  direction       = "EGRESS"
  action          = "deny"
  enable_logging  = true

  target_secure_tags {
    name = google_tags_tag_value.quarantine[each.key].id
  }

  match {
    dest_ip_ranges = ["0.0.0.0/0"]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}

resource "google_compute_network_firewall_policy_rule" "quarantine_ingress" {
  for_each = local.restricted_vpcs

  project         = each.value.project
  firewall_policy = google_compute_network_firewall_policy.vpc[each.key].name
  rule_name       = "quarantine-deny-ingress"
  priority        = 101
  direction       = "INGRESS"
  action          = "deny"
  enable_logging  = true

  target_secure_tags {
    name = google_tags_tag_value.quarantine[each.key].id
  }

  match {
    src_ip_ranges = ["0.0.0.0/0"]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}
