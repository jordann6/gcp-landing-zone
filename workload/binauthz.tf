# Binary Authorization: admission requires a signed attestation.
#
# The runtime half of the supply chain. An image runs on this cluster only if
# its digest carries an attestation signed by the KMS key below. Google-managed
# system images are exempt through the global policy, so the cluster itself can
# start. make test deploys an unsigned image and expects the admission denial;
# scripts/sign-image.sh signs a digest and shows the same image admitted.
#
# The build-side half (Cloud Build provenance, a scan gate that signs only
# clean digests) is gcp-supply-chain-security, reused here by the same attestor
# contract rather than rebuilt.

resource "google_kms_key_ring" "attestor" {
  project  = local.project
  name     = "binauthz-${var.env}"
  location = var.region
}

resource "google_kms_crypto_key" "attestor" {
  # checkov:skip=CKV_GCP_82: deploy-demo-destroy build, documented teardown.
  # checkov:skip=CKV_GCP_43: asymmetric signing keys do not support automatic
  # rotation; a new key version is added to the attestor instead.
  name     = "attestor"
  key_ring = google_kms_key_ring.attestor.id
  purpose  = "ASYMMETRIC_SIGN"

  version_template {
    algorithm = "EC_SIGN_P256_SHA256"
  }

  lifecycle {
    prevent_destroy = false
  }
}

data "google_kms_crypto_key_version" "attestor" {
  crypto_key = google_kms_crypto_key.attestor.id
}

resource "google_container_analysis_note" "attested" {
  project = local.project
  name    = "paved-road-approved"

  attestation_authority {
    hint {
      human_readable_name = "Approved for the ${var.env} paved road"
    }
  }
}

resource "google_binary_authorization_attestor" "approved" {
  project     = local.project
  name        = "paved-road-approved"
  description = "Signs digests approved for ${var.env}. The signing key is Cloud KMS; nobody holds it."

  attestation_authority_note {
    note_reference = google_container_analysis_note.attested.name

    public_keys {
      id = data.google_kms_crypto_key_version.attestor.id
      pkix_public_key {
        public_key_pem      = data.google_kms_crypto_key_version.attestor.public_key[0].pem
        signature_algorithm = data.google_kms_crypto_key_version.attestor.public_key[0].algorithm
      }
    }
  }
}

resource "google_binary_authorization_policy" "cluster" {
  project = local.project

  # Exempts Google-maintained system images (kube-system, GKE add-ons).
  global_policy_evaluation_mode = "ENABLE"

  default_admission_rule {
    evaluation_mode         = "REQUIRE_ATTESTATION"
    enforcement_mode        = var.binauthz_enforcement
    require_attestations_by = [google_binary_authorization_attestor.approved.name]
  }
}

# The Binary Authorization service agent verifies attestations at admission.
resource "google_binary_authorization_attestor_iam_member" "verifier" {
  project  = local.project
  attestor = google_binary_authorization_attestor.approved.name
  role     = "roles/binaryauthorization.attestorsVerifier"
  member   = "serviceAccount:service-${local.number}@gcp-sa-binaryauthorization.iam.gserviceaccount.com"
}
