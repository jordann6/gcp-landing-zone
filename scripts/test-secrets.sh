#!/usr/bin/env bash
# Prove the secrets lifecycle (needs make deploy-workload, make deploy-incident
# and make deploy-observability with enable_incident_channel, and
# scripts/set-db-password.sh run once).
#
#   State       no secret value in any Terraform state object in the state
#               bucket: no sensitive-named string attribute, no random_password
#               or secret version resource, and the live DB password itself does
#               not appear anywhere in the state
#   Rotation    the secret has a 30 day schedule and a topic; moving its next
#               rotation time to now makes Secret Manager publish SECRET_ROTATE,
#               read back from the secret-rotation subscription
#   Age alert   the proof job (limit -1) makes the handler log stale_secret for
#               the DB secret, and the ops alert opens
#
# Reads and writes go through sa-terraform (the topic, secret and perimeter are
# restricted). The value of the secret is read once, compared, and never printed.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

POLL_SECONDS="${POLL_SECONDS:-900}"
BUCKET="$(tfout bootstrap state_bucket)"
SEED="$(tfout bootstrap seed_project_id)"
PROJECT="$(tfout workload project_id)"
SECRET="$(tfout workload db_secret | sed 's|.*/||')"
H="$(tfjson incident handler)"
LOGGING="$(jq -r .project <<<"$H")"
REGION="$(jq -r .region <<<"$H")"
PROOF_JOB="$(jq -r .age_proof_job <<<"$H")"
TOKEN="$(gcloud auth print-access-token "$IMP" 2>/dev/null)"
api() { curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $SEED" "$@"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

section "No secret value in Terraform state"
VALUE="$(gcloud secrets versions access latest --secret="$SECRET" --project="$PROJECT" "$IMP" 2>/dev/null)"
[ -n "$VALUE" ] && ok "live secret value read for comparison (not printed)" || skip "secret has no version yet; value comparison skipped"
OBJECTS="$(gcloud storage ls -r "gs://$BUCKET/**" "$IMP" 2>/dev/null | grep -E '\.tfstate$' || true)"
N=0
while read -r obj; do
	[ -z "$obj" ] && continue
	N=$((N + 1))
	f="$TMP/state.$N"
	gcloud storage cat "$obj" "$IMP" >"$f" 2>/dev/null || { bad "could not read $obj"; continue; }
	name="${obj#gs://"$BUCKET"/}"
	HITS="$(jq '[.. | objects | to_entries[] | select(.key | test("^(password|root_password|secret_data|private_key|client_secret|api_key|access_token)$")) | select(.value | type == "string" and length > 0)] | length' "$f" 2>/dev/null)"
	[ "${HITS:-1}" = "0" ] && ok "$name: no sensitive-named string attribute" || bad "$name: $HITS sensitive-named string attributes"
	BAD="$(jq -r '[.resources[]? | select(.type == "random_password" or .type == "google_secret_manager_secret_version") | "\(.type).\(.name)"] | join(",")' "$f" 2>/dev/null)"
	[ -z "$BAD" ] && ok "$name: no random_password or secret version resource" || bad "$name tracks $BAD"
	if [ -n "$VALUE" ]; then
		if grep -qF -- "$VALUE" "$f"; then bad "$name CONTAINS the live DB password"; else ok "$name: live DB password not present"; fi
	fi
done <<<"$OBJECTS"
[ "$N" -gt 0 ] && ok "scanned $N state objects" || bad "no state objects found in gs://$BUCKET"

section "Rotation schedule and notification"
SJSON="$(gcloud secrets describe "$SECRET" --project="$PROJECT" --format=json "$IMP" 2>/dev/null)"
[ "$(jq -r '.rotation.rotationPeriod // empty' <<<"$SJSON")" = "2592000s" ] && ok "30 day rotation period set" || bad "rotation period: $(jq -r '.rotation.rotationPeriod // "none"' <<<"$SJSON")"
jq -e '.topics[]? | select(.name | endswith("/topics/secret-rotation"))' <<<"$SJSON" >/dev/null 2>&1 && ok "secret publishes to the secret-rotation topic" || bad "no secret-rotation topic on the secret"
SUB="projects/$PROJECT/subscriptions/secret-rotation-sub"
# Drain anything already queued so the pull below can only match this run.
for _ in 1 2 3; do gcloud pubsub subscriptions pull "$SUB" --auto-ack --limit=50 "$IMP" >/dev/null 2>&1; done
DUE="$(date -u -v+6M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+6 minutes' +%Y-%m-%dT%H:%M:%SZ)"
# The API rejects a rotation time less than 5 minutes out.
if UPD="$(gcloud secrets update "$SECRET" --project="$PROJECT" --next-rotation-time="$DUE" "$IMP" 2>&1)"; then
	ok "next rotation time moved to $DUE"
else
	bad "could not move next rotation time" "$UPD"
fi
FOUND=""
SECONDS=0
while [ "$SECONDS" -lt "$POLL_SECONDS" ]; do
	MSG="$(gcloud pubsub subscriptions pull "$SUB" --auto-ack --limit=10 --format=json "$IMP" 2>/dev/null)"
	if jq -e '[.[]?.message.attributes.eventType] | index("SECRET_ROTATE")' <<<"$MSG" >/dev/null 2>&1; then FOUND=1; break; fi
	sleep 15
done
[ -n "$FOUND" ] && ok "SECRET_ROTATE published for $SECRET after ${SECONDS}s" || bad "no SECRET_ROTATE within ${POLL_SECONDS}s"
NEXT="$(gcloud secrets describe "$SECRET" --project="$PROJECT" --format='value(rotation.nextRotationTime)' "$IMP" 2>/dev/null)"
echo "        Secret Manager advanced next rotation to ${NEXT:-unknown}"

section "Age alert: proof job with limit -1"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -z "$VALUE" ]; then
	skip "no secret version, so there is nothing to age"
else
	gcloud scheduler jobs run "$PROOF_JOB" --location="$REGION" --project="$LOGGING" "$IMP" >/dev/null 2>&1 && ok "ran $PROOF_JOB" || bad "could not run $PROOF_JOB"
	LOG=""
	SECONDS=0
	while [ "$SECONDS" -lt 240 ]; do
		LOG="$(gcloud logging read "resource.type=\"cloud_run_revision\" AND jsonPayload.event=\"stale_secret\" AND timestamp>=\"$START\"" --project="$LOGGING" --limit=1 --format=json "$IMP" 2>/dev/null | jq -c '.[0].jsonPayload // empty')"
		[ -n "$LOG" ] && break
		sleep 10
	done
	[ -n "$LOG" ] && ok "handler logged stale_secret: $(jq -c '{secret, age_days, limit_days}' <<<"$LOG")" || bad "no stale_secret log within 240s"
	POLICY="lz-ops-stale-secret"
	ALERT=""
	SECONDS=0
	while [ "$SECONDS" -lt "$POLL_SECONDS" ]; do
		ALERT="$(api -G "https://monitoring.googleapis.com/v3/projects/${LOGGING}/alerts" --data-urlencode "filter=policy.display_name=\"${POLICY}\" AND open_time>=\"${START}\"" | jq -c '.alerts[0] // empty')"
		[ -n "$ALERT" ] && break
		sleep 30
	done
	[ -n "$ALERT" ] && ok "$POLICY opened an alert: $(jq -r '"state=\(.state) opened=\(.openTime)"' <<<"$ALERT")" || bad "$POLICY did not open an alert within ${POLL_SECONDS}s"
fi

summary
