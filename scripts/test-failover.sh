#!/usr/bin/env bash
# Cloud SQL HA failover drill with a client-side write probe.
#
# Measures what an application sees, not only what the control plane reports:
#   write outage  the longest run of failed writes, from the last committed
#                 write before it to the first committed write after it
#   write loss    acknowledged writes missing when the table is read back
#   control plane the failover operation's own duration, and the zone change
#
# Needs make deploy-workload and make set-db-password. Takes about 5 minutes.
# The failover is a real outage of the primary for its duration; nothing else
# depends on this database outside a session.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$SA"

DURATION="${DURATION:-240}"
LEAD="${LEAD:-45}"
PROJECT="$(tfout workload project_id)"
CLUSTER="$(tfjson workload cluster)"
SQL="$(tfjson workload sql)"
DB="$(jq -r .primary <<<"$SQL")"
DB_IP="$(jq -r .private_ip <<<"$SQL")"
REGISTRY="$(tfout workload registry)"
VPCS="$(tfjson network vpcs)"
PSA_RANGE="$(jq -r '[.[] | select(.restricted and .env == "prod")][0].psa_range' <<<"$VPCS")"
K8S="$ROOT/workload/k8s"
RUN_ID="drill-$(date -u +%Y%m%d%H%M%S)"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

section "Setup"
gcloud container clusters get-credentials "$(jq -r .name <<<"$CLUSTER")" --zone="$(jq -r .location <<<"$CLUSTER")" --project="$PROJECT" --dns-endpoint >/dev/null 2>&1 &&
	ok "cluster reachable" || { bad "could not reach the cluster"; summary; exit 1; }
kubectl apply -f "$K8S/00-namespaces.yaml" >/dev/null
PSA_RANGE="$PSA_RANGE" PSC_IP="10.3.255.254" envsubst '${PSA_RANGE} ${PSC_IP}' <"$K8S/10-netpol.yaml" | kubectl apply -f - >/dev/null
PG_IMAGE="$("$ROOT/scripts/sign-image.sh" "$REGISTRY/library/postgres:16-alpine")"
SDK_IMAGE="$("$ROOT/scripts/sign-image.sh" "$REGISTRY/google/cloud-sdk:slim")"
[ -n "$PG_IMAGE" ] && [ -n "$SDK_IMAGE" ] && ok "images attested" || { bad "could not sign images"; summary; exit 1; }
Z1="$(gcloud sql instances describe "$DB" --project="$PROJECT" --format='value(gceZone)')"
ok "primary $DB in $Z1"

kubectl -n app delete job write-probe --ignore-not-found >/dev/null 2>&1
PROJECT="$PROJECT" DB_IP="$DB_IP" PG_IMAGE="$PG_IMAGE" SDK_IMAGE="$SDK_IMAGE" RUN_ID="$RUN_ID" DURATION="$DURATION" \
	envsubst '${PROJECT} ${DB_IP} ${PG_IMAGE} ${SDK_IMAGE} ${RUN_ID} ${DURATION}' <"$K8S/30-write-probe.yaml" | kubectl apply -f - >/dev/null
# The pod is created asynchronously by the Job controller, and kubectl wait on a
# label selector fails at once when nothing matches yet. Wait for the pod to
# exist, then for its main container to run (the first pull through the
# registry cache can take a couple of minutes).
SECONDS=0
until kubectl -n app get pods -l job-name=write-probe -o name 2>/dev/null | grep -q . || [ "$SECONDS" -ge 60 ]; do sleep 3; done
kubectl -n app wait --for=jsonpath='{.status.phase}'=Running pod -l job-name=write-probe --timeout=360s >/dev/null 2>&1 &&
	ok "write probe running ($RUN_ID, ${DURATION}s)" || { bad "write probe did not start" "$(kubectl -n app logs job/write-probe --all-containers 2>&1 | tail -3)"; summary; exit 1; }
# The probe needs a few committed writes before the failover means anything.
SECONDS=0
until kubectl -n app logs job/write-probe -c probe 2>/dev/null | grep -q '^ok ' || [ "$SECONDS" -ge 120 ]; do sleep 3; done

section "Failover under write load"
echo "        steady writes for ${LEAD}s, then failover"
sleep "$LEAD"
T0=$(date +%s)
if gcloud sql instances failover "$DB" --project="$PROJECT" --quiet >/dev/null 2>&1; then
	T1=$(date +%s)
	Z2="$(gcloud sql instances describe "$DB" --project="$PROJECT" --format='value(gceZone)')"
	[ "$Z1" != "$Z2" ] && ok "failed over $Z1 -> $Z2; operation took $((T1 - T0))s" || bad "zone did not change ($Z1)"
else
	bad "failover command failed"
fi

kubectl -n app wait --for=condition=complete job/write-probe --timeout=$((DURATION + 300))s >/dev/null 2>&1 || bad "write probe did not complete"
kubectl -n app logs job/write-probe -c probe >"$OUT" 2>/dev/null

section "What the client saw"
SUMMARY="$(grep '^summary' "$OUT")"
[ -n "$SUMMARY" ] || { bad "no summary from the probe" "$(tail -5 "$OUT")"; summary; exit 1; }
# Longest outage: from the last ok before an err run to the first ok after it.
read -r OUTAGE FAILED <<<"$(awk '
	$1 == "ok"  { if (inerr) { gap = $3 - lastok; if (gap > best) best = gap; inerr = 0 } lastok = $3 }
	$1 == "err" { inerr = 1; errs++ }
	END { printf "%.1f %d\n", best, errs }' "$OUT")"
LOST="$(sed -n 's/.*lost=\([0-9-]*\).*/\1/p' <<<"$SUMMARY")"
ACKED="$(sed -n 's/.*acked=\([0-9]*\).*/\1/p' <<<"$SUMMARY")"
[ "${FAILED:-0}" -gt 0 ] && ok "write outage ${OUTAGE}s ($FAILED failed attempts)" || skip "no failed writes observed (probe interval may have missed the cutover)"
[ "$LOST" = "0" ] && ok "0 of $ACKED acknowledged writes lost" || bad "$LOST of $ACKED acknowledged writes missing after failover"
echo "        $SUMMARY"

kubectl -n app delete job write-probe --ignore-not-found >/dev/null 2>&1
summary
