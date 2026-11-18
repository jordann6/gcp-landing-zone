#!/usr/bin/env bash
# Prove a real rotation end to end: Secret Manager's schedule fires, the rotator
# sets a new Cloud SQL password and adds it as a new version, older versions are
# disabled, and an app pod connects with the new password.
#
# Needs make deploy-workload, make set-db-password (once), make deploy-rotation
# twice (identities, then after make build-rotator).
#
#   Ignore     a SECRET_UPDATE event and a SECRET_ROTATE for another secret are
#              acknowledged and skipped: no new version
#   Rotate     the schedule is moved to now + 6 minutes (the API minimum is 5);
#              SECRET_ROTATE reaches the rotator, which rotates
#   Retire     exactly one version is enabled afterwards, the new one
#   Connect    the paved-road db-check job reads latest through Workload
#              Identity and connects to Cloud SQL over TLS with it
#   State      the new value is in no Terraform state object
#
# Runs as sa-terraform (the secret, topic and Cloud SQL are inside VPC-SC).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$SA"

POLL_SECONDS="${POLL_SECONDS:-900}"
BUCKET="$(tfout bootstrap state_bucket)"
R="$(tfjson rotation rotator)"
[ -n "$R" ] && [ "$R" != "null" ] || { echo "rotation/ has no deployed rotator; make build-rotator then make deploy-rotation" >&2; exit 1; }
PROJECT="$(jq -r .project <<<"$R")"
SECRET_PATH="$(jq -r .secret <<<"$R")"
SECRET="${SECRET_PATH##*/}"
TOPIC="$(tfout workload rotation_topic)"

epoch() { date -j -u -f %Y-%m-%dT%H:%M:%S "$1" +%s 2>/dev/null || date -u -d "$1" +%s; }
enabled() { gcloud secrets versions list "$SECRET" --project="$PROJECT" --filter="state=ENABLED" --format="value(name)" 2>/dev/null | sed 's|.*/||' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
rlog() { gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"secret-rotator\" AND jsonPayload.event=\"$1\" AND timestamp>=\"$2\"" --project="$PROJECT" --limit=10 --format=json 2>/dev/null; }

BEFORE="$(enabled)"
[ -n "$BEFORE" ] || { echo "the secret has no enabled version; run make set-db-password first" >&2; exit 1; }

section "Ignore what is not a rotation of this secret"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
gcloud pubsub topics publish "$TOPIC" --message="{}" --attribute="eventType=SECRET_UPDATE,secretId=$SECRET_PATH" >/dev/null 2>&1 && ok "published SECRET_UPDATE" || bad "could not publish SECRET_UPDATE"
gcloud pubsub topics publish "$TOPIC" --message="{}" --attribute="eventType=SECRET_ROTATE,secretId=projects/$PROJECT/secrets/not-this-one" >/dev/null 2>&1 && ok "published SECRET_ROTATE for another secret" || bad "could not publish the decoy"
N=0
SECONDS=0
while [ "$SECONDS" -lt 240 ]; do
	N="$(rlog skipped "$START" | jq length)"
	[ "${N:-0}" -ge 2 ] && break
	sleep 10
done
[ "${N:-0}" -ge 2 ] && ok "rotator skipped both ($(rlog skipped "$START" | jq -r '[.[].jsonPayload.reason] | join("; ")' | cut -c1-160))" || bad "rotator logged $N skips within 240s (cold start with Direct VPC egress can be slow; rerun)"
[ "$(enabled)" = "$BEFORE" ] && ok "no version added by either: enabled = $BEFORE" || bad "versions changed: $BEFORE -> $(enabled)"

section "Scheduled rotation"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DUE="$(date -u -v+6M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+6 minutes' +%Y-%m-%dT%H:%M:%SZ)"
if UPD="$(gcloud secrets update "$SECRET" --project="$PROJECT" --next-rotation-time="$DUE" 2>&1)"; then
	ok "next rotation time moved to $DUE"
else
	bad "could not move next rotation time" "$UPD"
fi
LOG=""
SECONDS=0
while [ "$SECONDS" -lt "$POLL_SECONDS" ]; do
	LOG="$(rlog rotated "$START" | jq -c '.[0] // empty')"
	[ -n "$LOG" ] && break
	sleep 15
done
if [ -n "$LOG" ]; then
	AT="$(jq -r .timestamp <<<"$LOG")"
	AT="${AT%%.*}"
	AT="${AT%Z}"
	LAG=$(($(epoch "$AT") - $(epoch "${DUE%Z}")))
	ok "rotated: $(jq -c '.jsonPayload | {version, disabled, seconds}' <<<"$LOG"), ${LAG}s after the scheduled time"
else
	bad "no rotation within ${POLL_SECONDS}s" "$(rlog rotation_failed "$START" | jq -r '.[0].jsonPayload.error // "no rotation_failed log either"')"
fi

section "Retire the old versions"
AFTER="$(enabled)"
NEW=""
[ -n "$LOG" ] && NEW="$(jq -r '.jsonPayload.version // empty' <<<"$LOG")"
[ -n "$NEW" ] && [ "$AFTER" = "$NEW" ] && ok "exactly one enabled version, the new one ($NEW)" || bad "enabled after rotation: '$AFTER' (expected '$NEW')"
for v in $BEFORE; do
	S="$(gcloud secrets versions describe "$v" --secret="$SECRET" --project="$PROJECT" --format='value(state)' 2>/dev/null)"
	[ "$S" = "DISABLED" ] && ok "version $v DISABLED" || bad "version $v is $S"
done

section "The app connects with the new password"
CLUSTER="$(tfjson workload cluster)"
DB_IP="$(tfjson workload sql | jq -r .private_ip)"
REGISTRY="$(tfout workload registry)"
VPCS="$(tfjson network vpcs)"
PSA_RANGE="$(jq -r '[.[] | select(.restricted and .env == "prod")][0].psa_range' <<<"$VPCS")"
K8S="$ROOT/workload/k8s"
if gcloud container clusters get-credentials "$(jq -r .name <<<"$CLUSTER")" --zone="$(jq -r .location <<<"$CLUSTER")" --project="$PROJECT" --dns-endpoint >/dev/null 2>&1; then
	kubectl apply -f "$K8S/00-namespaces.yaml" >/dev/null
	PSA_RANGE="$PSA_RANGE" PSC_IP="10.3.255.254" envsubst '${PSA_RANGE} ${PSC_IP}' <"$K8S/10-netpol.yaml" | kubectl apply -f - >/dev/null
	PG_IMAGE="$("$ROOT/scripts/sign-image.sh" "$REGISTRY/library/postgres:16-alpine")"
	SDK_IMAGE="$("$ROOT/scripts/sign-image.sh" "$REGISTRY/google/cloud-sdk:slim")"
	kubectl -n app delete job db-check --ignore-not-found >/dev/null 2>&1
	PROJECT="$PROJECT" DB_IP="$DB_IP" PG_IMAGE="$PG_IMAGE" SDK_IMAGE="$SDK_IMAGE" \
		envsubst '${PROJECT} ${DB_IP} ${PG_IMAGE} ${SDK_IMAGE}' <"$K8S/20-db-check.yaml" | kubectl apply -f - >/dev/null
	if kubectl -n app wait --for=condition=complete job/db-check --timeout=300s >/dev/null 2>&1; then
		LINE="$(kubectl -n app logs job/db-check -c psql 2>/dev/null | tail -1)"
		[ "$LINE" = "connected over tls" ] && ok "db-check read version $NEW and connected over TLS" || bad "unexpected result: $LINE"
	else
		bad "db-check did not complete" "$(kubectl -n app logs job/db-check --all-containers 2>&1 | tail -5)"
	fi
else
	bad "could not reach the cluster"
fi

section "The new value is in no Terraform state"
VALUE="$(gcloud secrets versions access latest --secret="$SECRET" --project="$PROJECT" 2>/dev/null)"
if [ -z "$VALUE" ]; then
	bad "could not read the new value for comparison"
else
	HIT=0 N=0
	while read -r obj; do
		[ -z "$obj" ] && continue
		N=$((N + 1))
		gcloud storage cat "$obj" 2>/dev/null | grep -qF -- "$VALUE" && { HIT=1; bad "${obj#gs://"$BUCKET"/} CONTAINS the new password"; }
	done <<<"$(gcloud storage ls -r "gs://$BUCKET/**" 2>/dev/null | grep -E '\.tfstate$')"
	[ "$HIT" = 0 ] && [ "$N" -gt 0 ] && ok "new password in none of $N state objects"
fi
unset VALUE

summary
