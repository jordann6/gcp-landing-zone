#!/usr/bin/env bash
# Prove event remediation end to end, through the real org asset feed.
#
#   Firewall   a VPC firewall rule admitting tcp:22 from 0.0.0.0/0 is created
#              in the restricted prod host (targeting a tag no instance has, and
#              behind the org policy's internet-ingress deny either way); the
#              handler disables it, timed from the create
#   IAM        roles/editor is granted to the operator on the prod app project
#              with no condition (a standing grant, outside PAM); the handler
#              removes it, timed
#   Leave      roles/viewer on the same principal is not a primitive admin
#              grant, so it stays
#   Page       lz-ops-remediation-applied opens
#
# Needs the incident root deployed with -var dry_run=false and observability
# with enable_incident_channel. Cleans up after itself whatever happens.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$SA"

POLL="${POLL_SECONDS:-600}"
H="$(tfjson incident handler)"
[ "$(jq -r .dry_run <<<"$H")" = "false" ] || { echo "the handler is in dry-run; apply incident/ with -var dry_run=false first" >&2; exit 1; }
LOGGING="$(jq -r .project <<<"$H")"
APP="$(tfout workload project_id)"
VPC="$(tfjson network vpcs | jq -c '[.[] | select(.restricted and .env == "prod")][0]')"
HOST="$(jq -r .project <<<"$VPC")"
NET="$(jq -r .network_name <<<"$VPC")"
OPERATOR="user:$(CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT='' gcloud config get-value account 2>/dev/null)"
RULE="lz-drill-open-ssh-$(date +%s)"

cleanup() {
	gcloud compute firewall-rules delete "$RULE" --project="$HOST" --quiet >/dev/null 2>&1 || true
	# Remove with the member exactly as IAM stores it (canonical casing).
	local m
	m="$(gcloud projects get-iam-policy "$APP" --format=json 2>/dev/null | jq -r --arg m "$OPERATOR" '[.bindings[]?.members[] | select(ascii_downcase == ($m | ascii_downcase))][0] // empty')"
	[ -n "$m" ] || return 0
	for role in roles/editor roles/viewer; do
		gcloud projects remove-iam-policy-binding "$APP" --member="$m" --role="$role" --condition=None >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

# Polls: Cloud Logging indexes entries a few seconds to a minute after they are written.
hlog() {
	local out=""
	for _ in $(seq 1 12); do
		out="$(gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"incident-handler\" AND jsonPayload.event=\"handled\" AND jsonPayload.action=\"$1\" AND timestamp>=\"$2\"" --project="$LOGGING" --limit=1 --format=json 2>/dev/null | jq -c '.[0].jsonPayload // empty')"
		[ -n "$out" ] && break
		sleep 10
	done
	printf '%s' "$out"
}
# IAM stores a user in the Google account's canonical casing, which need not
# match gcloud's account name, so members compare case-insensitively.
has_binding() { gcloud projects get-iam-policy "$APP" --format=json 2>/dev/null | jq -e --arg r "$1" --arg m "$OPERATOR" '[.bindings[]? | select(.role == $r and (.condition == null)) | .members[] | ascii_downcase] | index($m | ascii_downcase) != null' >/dev/null; }

section "Firewall: 0.0.0.0/0 ingress"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T0=$(date +%s)
if gcloud compute firewall-rules create "$RULE" --project="$HOST" --network="$NET" --direction=INGRESS \
	--source-ranges=0.0.0.0/0 --allow=tcp:22 --target-tags=lz-drill-nothing-has-this --quiet >/dev/null 2>&1; then
	ok "created $RULE in $HOST"
else
	bad "could not create the drill rule"
fi
D=""
while [ $(($(date +%s) - T0)) -lt "$POLL" ]; do
	D="$(gcloud compute firewall-rules describe "$RULE" --project="$HOST" --format='value(disabled)' 2>/dev/null)"
	[ "$D" = "True" ] && break
	sleep 10
done
[ "$D" = "True" ] && ok "handler disabled $RULE $(($(date +%s) - T0))s after it was created" || bad "$RULE still enabled after ${POLL}s"
L="$(hlog remediate_firewall "$START")"
[ -n "$L" ] && ok "handler logged $(jq -c '{action, firewall, dry_run}' <<<"$L")" || bad "no remediate_firewall log"

section "IAM: standing human editor"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gcloud projects add-iam-policy-binding "$APP" --member="$OPERATOR" --role=roles/viewer --condition=None >/dev/null 2>&1 && ok "granted roles/viewer (should stay)" || bad "could not grant viewer"
T0=$(date +%s)
gcloud projects add-iam-policy-binding "$APP" --member="$OPERATOR" --role=roles/editor --condition=None >/dev/null 2>&1 && ok "granted roles/editor with no condition" || bad "could not grant editor"
GONE=""
while [ $(($(date +%s) - T0)) -lt "$POLL" ]; do
	has_binding roles/editor || { GONE=1; break; }
	sleep 10
done
[ -n "$GONE" ] && ok "handler removed the editor grant $(($(date +%s) - T0))s after it was made" || bad "editor grant still present after ${POLL}s"
has_binding roles/viewer && ok "roles/viewer left in place" || bad "roles/viewer was removed too"
L="$(hlog remediate_iam "$START")"
[ -n "$L" ] && ok "handler logged $(jq -c '{action, removed: (.removed | length), dry_run}' <<<"$L")" || bad "no remediate_iam log"

section "Page"
SEED="$(tfout bootstrap seed_project_id)"
A=""
SECONDS=0
while [ "$SECONDS" -lt 600 ]; do
	A="$(curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" -H "x-goog-user-project: $SEED" \
		"https://monitoring.googleapis.com/v3/projects/$LOGGING/alerts" \
		--data-urlencode "filter=policy.display_name=\"lz-ops-remediation-applied\" AND open_time>=\"$START\"" | jq -c '.alerts[0] // empty')"
	[ -n "$A" ] && break
	sleep 30
done
[ -n "$A" ] && ok "lz-ops-remediation-applied opened" || bad "no remediation alert within 600s"

summary
