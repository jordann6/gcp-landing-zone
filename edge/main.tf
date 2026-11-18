# The edge: a global external Application Load Balancer in front of private GKE,
# with Cloud Armor deciding what reaches the pods.
#
#   client -> Google front end (anycast IP) -> Cloud Armor -> NEG -> pod
#
# Terraform owns the two things that must outlive any one Ingress: the reserved
# global address and the Cloud Armor policy. The load balancer itself (forwarding
# rule, URL map, backend service, NEGs, health check) is created by the GKE
# Ingress controller from workload/k8s/40-edge.yaml, which names both. That is
# the documented GKE pattern; a Terraform-built URL map in front of
# controller-managed NEGs fights the controller.
#
# Nodes stay private. Traffic enters through container-native NEGs from the
# Google front-end ranges, which the org firewall policy already admits
# (allow-health-checks, the same 35.191.0.0/16 and 130.211.0.0/22), and a
# NetworkPolicy admits only those ranges to the web pods.
#
# Mirrors the Azure zone's Front Door WAF and the AWS zone's CloudFront in
# purpose. HTTP only: a Google-managed certificate needs a domain this demo
# does not own, so TLS at the edge is documented, not proven (ADR-0007).

locals {
  gov     = data.terraform_remote_state.governance.outputs
  project = local.gov.app_projects["app-${var.env}"].project_id
}

resource "google_project_service" "compute" {
  project            = local.project
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_global_address" "edge" {
  project = local.project
  name    = "edge-${var.env}"

  depends_on = [google_project_service.compute]
}

resource "google_compute_security_policy" "edge" {
  project     = local.project
  name        = "edge-${var.env}"
  description = "WAF, per-IP rate limit, default allow. Attached to the web backend by BackendConfig."
  type        = "CLOUD_ARMOR"

  advanced_options_config {
    json_parsing = "STANDARD"
    log_level    = "VERBOSE"
  }

  rule {
    priority    = 1000
    action      = "deny(403)"
    description = "SQL injection (OWASP CRS, preconfigured)"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': ${var.waf_sensitivity}})"
      }
    }
  }

  rule {
    priority    = 1010
    action      = "deny(403)"
    description = "Cross-site scripting (OWASP CRS, preconfigured)"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': ${var.waf_sensitivity}})"
      }
    }
  }

  rule {
    priority    = 1020
    action      = "deny(403)"
    description = "Local file inclusion and path traversal"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('lfi-v33-stable', {'sensitivity': ${var.waf_sensitivity}})"
      }
    }
  }

  rule {
    priority    = 1030
    action      = "deny(403)"
    description = "Log4j JNDI lookup (CVE-2021-44228 and variants)"
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('cve-canary')"
      }
    }
  }

  rule {
    priority    = 2000
    action      = "throttle"
    description = "Per-client-IP rate limit"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = var.rate_limit_per_minute
        interval_sec = 60
      }
    }
  }

  rule {
    priority    = 2147483647
    action      = "allow"
    description = "Default allow"
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  depends_on = [google_project_service.compute]
}
