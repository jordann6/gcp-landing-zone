# Data-tier segmentation.
#
# Who can talk to whom, enforced at three layers:
#
#   Between environments   separate VPCs in separate host projects, no peering.
#                          dev's data tier has no route to prod's at all.
#   Within prod, VPC       only the GKE nodes (identified by their service
#                          account, not an IP) reach the PSA range, and only on
#                          5432. Everything else in the VPC, the probe VM
#                          included, is denied before the network root's
#                          allow-internal rule is reached.
#   Within the cluster     NetworkPolicy (k8s/10-netpol.yaml) narrows the node
#                          allowance to pods labelled tier=app in the app
#                          namespace. Dataplane V2 enforces it.
#
# These rules live in the network root's firewall policy for this VPC but are
# owned here, because they name the workload's own identity.
#
#   from \ to        | Cloud SQL :5432 | Cloud SQL other | internet
#   app pods         | allow           | deny            | FQDN allowlist
#   other pods       | deny (netpol)   | deny            | FQDN allowlist
#   other VMs/probe  | deny            | deny            | FQDN allowlist
#   dev / test       | no route        | no route        | own VPC rules

resource "google_compute_network_firewall_policy_rule" "app_to_db" {
  project         = local.vpc.project
  firewall_policy = local.vpc.firewall_policy
  rule_name       = "allow-app-to-db"
  description     = "GKE nodes to Cloud SQL on 5432 only."
  priority        = 800
  direction       = "EGRESS"
  action          = "allow"
  enable_logging  = true

  target_service_accounts = [google_service_account.nodes.email]

  match {
    dest_ip_ranges = [local.vpc.psa_range]
    layer4_configs {
      ip_protocol = "tcp"
      ports       = ["5432"]
    }
  }
}

resource "google_compute_network_firewall_policy_rule" "deny_other_to_db" {
  project         = local.vpc.project
  firewall_policy = local.vpc.firewall_policy
  rule_name       = "deny-other-to-db"
  description     = "Anything else to the data tier is denied, ahead of the VPC's allow-internal rule."
  priority        = 850
  direction       = "EGRESS"
  action          = "deny"
  enable_logging  = true

  match {
    dest_ip_ranges = [local.vpc.psa_range]
    layer4_configs {
      ip_protocol = "all"
    }
  }
}
