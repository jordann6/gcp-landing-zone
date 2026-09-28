#!/usr/bin/env bash
# Prove the governance and network controls DENY, not just that apply succeeded.
#
# Every check either expects a denial that names the specific control, or reads
# live effective state. Nothing here creates a billable resource that survives:
# the one write that is expected to succeed (a bucket in dev) is deleted at once.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

GOV="$(tfjson terraform app_projects)"
ORG="$(tfout terraform org_id)"
FOLDERS="$(tfjson terraform folders)"
LOGGING="$(tfout terraform logging_project_id)"
SANDBOX="$(tfjson terraform sandbox_project_id | jq -r '. // empty')"
APP_PROD="$(jq -r '."app-prod".project_id // empty' <<<"$GOV")"
APP_DEV="$(jq -r '."app-dev".project_id // empty' <<<"$GOV")"
REGION="us-central1"
STAMP="$(date +%s)"

section "Org policy: Google's pre-applied defaults are still enforced (and unmanaged)"
for c in $(tfjson terraform google_default_constraints | jq -r '.[]'); do
	if gcloud org-policies describe "$c" --organization="$ORG" --effective --format=json 2>/dev/null |
		jq -e '.spec.rules[]? | select(.enforce == true or .values != null)' >/dev/null; then
		ok "$c enforced"
	else
		bad "$c is NOT enforced (was it deleted by a destroy?)"
	fi
done

section "Org policy: denials name the constraint"

# A key cannot be minted even by the project owner.
PROBE_SA="$(gcloud iam service-accounts list --project="$LOGGING" "$IMP" --format='value(email)' 2>/dev/null | head -1)"
if [ -z "$PROBE_SA" ]; then
	PROBE_SA="$SA"
fi
# gcloud chmods its output file, so the key path must be a real file, not
# /dev/null. The denial means nothing is ever written; the dir is removed anyway.
KEYDIR="$(mktemp -d)"
expect_denied "service account key creation" "disableServiceAccountKeyCreation" \
	gcloud iam service-accounts keys create "$KEYDIR/key.json" --iam-account="$PROBE_SA" "$IMP"
rm -rf "$KEYDIR"

expect_denied "bucket outside approved locations" "resourceLocations" \
	gcloud storage buckets create "gs://lz-test-asia-${STAMP}" --location=asia-northeast1 --project="$LOGGING" "$IMP"

if [ -n "$SANDBOX" ]; then
	expect_denied "VM with an external IP" "vmExternalIpAccess" \
		gcloud compute instances create "lz-test-extip-${STAMP}" --project="$SANDBOX" --zone="${REGION}-a" \
		--machine-type=e2-micro --subnet="snet-sandbox-${REGION}" --image-family=debian-12 \
		--image-project=debian-cloud --shielded-secure-boot "$IMP"
else
	skip "VM external IP (sandbox not vended)"
fi

section "Inheritance: identical request, different outcome by placement"

if [ -n "$APP_PROD" ]; then
	# GCS words this denial without the constraint name.
	expect_denied "prod: bucket without CMEK" "restrictNonCmekServices|customer-managed encryption key \\(CMEK\\) on the bucket is required by an org policy" \
		gcloud storage buckets create "gs://lz-test-nocmek-prod-${STAMP}" --location="$REGION" --project="$APP_PROD" "$IMP"
else
	skip "prod CMEK requirement (app-prod not vended)"
fi

if [ -n "$APP_DEV" ]; then
	if gcloud storage buckets create "gs://lz-test-nocmek-dev-${STAMP}" --location="$REGION" --project="$APP_DEV" "$IMP" >/dev/null 2>&1; then
		ok "dev: the same bucket without CMEK is accepted"
		gcloud storage buckets delete "gs://lz-test-nocmek-dev-${STAMP}" "$IMP" --quiet >/dev/null 2>&1
	else
		bad "dev: bucket without CMEK was rejected (dev should not inherit prod's rule)"
	fi
	NETS="$(gcloud compute networks list --project="$APP_DEV" "$IMP" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
	[ "$NETS" = "0" ] && ok "freshly vended project has zero networks" || bad "vended project has $NETS networks"
else
	skip "dev comparison (app-dev not vended)"
fi

SANDBOX_FOLDER="$(jq -r .sandbox <<<"$FOLDERS")"
if gcloud org-policies describe gcp.resourceLocations --folder="${SANDBOX_FOLDER#folders/}" --effective --format=json 2>/dev/null | grep -q "eu-locations"; then
	ok "sandbox folder widens gcp.resourceLocations to EU (child policy override)"
else
	bad "sandbox folder does not show the EU widening"
fi
PROD_FOLDER="$(jq -r .prod <<<"$FOLDERS")"
if gcloud org-policies describe gcp.resourceLocations --folder="${PROD_FOLDER#folders/}" --effective --format=json 2>/dev/null | grep -q "eu-locations"; then
	bad "prod folder inherited EU locations"
else
	ok "prod folder resolves to US locations only"
fi

section "Custom constraints"
for c in $(tfjson terraform enforced_constraints | jq -r '.[] | select(startswith("custom."))'); do
	if gcloud org-policies describe "$c" --organization="$ORG" --effective --format=json 2>/dev/null | jq -e '.spec.rules[]? | select(.enforce == true)' >/dev/null; then
		ok "$c enforced"
	else
		bad "$c not enforced"
	fi
done

section "Identity"
POOL="$(tfout terraform workforce_pool)"
gcloud iam workforce-pools describe "${POOL##*/}" --location=global "$IMP" >/dev/null 2>&1 &&
	ok "workforce pool ${POOL##*/} exists" || bad "workforce pool missing"
ENT="$(gcloud pam entitlements list --location=global --folder="${PROD_FOLDER#folders/}" "$IMP" --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
[ "${ENT:-0}" -ge 1 ] && ok "PAM prod-write entitlement exists on the prod folder" || skip "PAM entitlement not found (enable_pam or gcloud pam unavailable)"

section "Logging"
# bq does not take gcloud's --impersonate-service-account flag; it honours the
# same setting as an environment property.
ROWS="$(CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$SA" bq --project_id="$LOGGING" query --use_legacy_sql=false --format=csv \
	"SELECT COUNT(*) FROM \`${LOGGING}.org_audit_logs.cloudaudit_googleapis_com_activity\`" 2>/dev/null | tail -1)"
[[ "${ROWS:-}" =~ ^[0-9]+$ ]] && [ "$ROWS" -gt 0 ] && ok "org sink delivering ($ROWS admin-activity rows)" ||
	skip "org sink has no rows yet (first delivery can take several minutes)"

section "Network (needs make deploy-network)"
PROBE="$(tfjson network probe 2>/dev/null)"
if [ -n "$PROBE" ] && [ "$PROBE" != "null" ]; then
	P_NAME="$(jq -r .name <<<"$PROBE")"
	P_ZONE="$(jq -r .zone <<<"$PROBE")"
	P_PROJ="$(jq -r .project <<<"$PROBE")"
	ssh_probe() {
		gcloud compute ssh "$P_NAME" --zone="$P_ZONE" --project="$P_PROJ" --tunnel-through-iap \
			--quiet --command="$1" 2>/dev/null
	}

	CODE="$(ssh_probe 'curl -s -m 10 -o /dev/null -w "%{http_code}" https://github.com')"
	[[ "$CODE" =~ ^(200|301|302)$ ]] && ok "allowlisted FQDN reachable (github.com -> $CODE)" || bad "github.com unreachable from the probe (got '$CODE')"

	CODE="$(ssh_probe 'curl -s -m 10 -o /dev/null -w "%{http_code}" https://example.com || true')"
	# Not ^(000|)$: bash 3.2 (macOS) never matches an empty ERE alternative.
	[[ -z "$CODE" || "$CODE" == "000" ]] && ok "non-allowlisted destination denied (example.com)" || bad "example.com reachable from the probe ($CODE)"

	IP="$(ssh_probe 'getent hosts storage.googleapis.com | cut -d" " -f1')"
	[[ "$IP" =~ ^10\. ]] && ok "storage.googleapis.com resolves to the PSC endpoint ($IP)" || bad "Google APIs resolve publicly ($IP)"

	EXT="$(gcloud compute instances describe "$P_NAME" --zone="$P_ZONE" --project="$P_PROJ" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null)"
	[ -z "$EXT" ] && ok "probe has no external IP" || bad "probe has external IP $EXT"

	# VPC-SC: the operator is outside the perimeter and not in its ingress rule.
	expect_denied "VPC-SC blocks the operator reading storage in the perimeter" "VPC Service Controls|vpcServiceControls|organization's policy" \
		gcloud storage buckets list --project="$P_PROJ"
	expect_ok "VPC-SC admits sa-terraform through the ingress rule" \
		gcloud storage buckets list --project="$P_PROJ" "$IMP"
else
	skip "network checks (network root not deployed, or probe disabled)"
fi

summary
