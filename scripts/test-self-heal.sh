#!/usr/bin/env bash
# Prove uptime monitoring and self-healing on the edge.
#
#   Break    the web Deployment behind the edge is scaled to 0 (the load
#            balancer answers 502)
#   Detect   the uptime check fails from multiple regions; lz-ops-edge-uptime
#            opens, timed from the break
#   Heal     the alert reaches the handler, web_heal scales app/web back to its
#            floor through the GKE DNS endpoint, and the edge serves 200 again,
#            timed from the break; nobody touched it
#
# Needs make test-edge (Ingress serving), the incident root with
# -var dry_run=false, and observability with enable_incident_channel=true and
# enable_edge_uptime=true.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$SA"

POLL="${POLL_SECONDS:-900}"
H="$(tfjson incident handler)"
[ "$(jq -r .dry_run <<<"$H")" = "false" ] || { echo "the handler is in dry-run; apply incident/ with -var dry_run=false first" >&2; exit 1; }
LOGGING="$(jq -r .project <<<"$H")"
PROJECT="$(tfout workload project_id)"
CLUSTER="$(tfjson workload cluster)"
IP="$(tfjson edge address | jq -r .ip)"
SEED="$(tfout bootstrap seed_project_id)"
gcloud container clusters get-credentials "$(jq -r .name <<<"$CLUSTER")" --zone="$(jq -r .location <<<"$CLUSTER")" --project="$PROJECT" --dns-endpoint >/dev/null 2>&1 ||
	{ echo "could not reach the cluster" >&2; exit 1; }
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$IP/"; }
alert() {
	curl -s -G -H "Authorization: Bearer $(gcloud auth print-access-token 2>/dev/null)" -H "x-goog-user-project: $SEED" \
		"https://monitoring.googleapis.com/v3/projects/$LOGGING/alerts" \
		--data-urlencode "filter=policy.display_name=\"lz-ops-edge-uptime\" AND open_time>=\"$1\"" | jq -c '.alerts[0] // empty'
}

section "Before"
[ "$(code)" = "200" ] && ok "edge serves 200" || { bad "edge is not serving; run make test-edge first"; summary; exit 1; }
BEFORE="$(kubectl -n app get deploy web -o jsonpath='{.spec.replicas}')"
ok "app/web at $BEFORE replicas"

section "Break"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T0=$(date +%s)
kubectl -n app scale deploy/web --replicas=0 >/dev/null && ok "scaled app/web to 0" || bad "scale failed"
DOWN="" OPEN="" UP=""
while [ $(($(date +%s) - T0)) -lt "$POLL" ]; do
	C="$(code)"
	[ -z "$DOWN" ] && [ "$C" != "200" ] && DOWN=$(($(date +%s) - T0))
	[ -z "$OPEN" ] && [ -n "$(alert "$START")" ] && OPEN=$(($(date +%s) - T0))
	if [ -n "$DOWN" ] && [ "$C" = "200" ]; then UP=$(($(date +%s) - T0)); break; fi
	sleep 10
done
[ -n "$DOWN" ] && ok "edge stopped serving ${DOWN}s after the break" || bad "edge never went down"
[ -n "$OPEN" ] && ok "lz-ops-edge-uptime opened ${OPEN}s after the break" || bad "no uptime alert"
[ -n "$UP" ] && ok "edge serving 200 again ${UP}s after the break, with no human action" || bad "edge did not recover within ${POLL}s"

section "Who healed it"
L="$(gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"incident-handler\" AND jsonPayload.action=\"web_heal\" AND timestamp>=\"$START\"" --project="$LOGGING" --limit=1 --format=json 2>/dev/null | jq -c '.[0].jsonPayload // empty')"
[ -n "$L" ] && ok "handler: $(jq -r .did <<<"$L")" || bad "no web_heal log from the handler"
AFTER="$(kubectl -n app get deploy web -o jsonpath='{.spec.replicas}')"
[ "${AFTER:-0}" -ge 2 ] && ok "app/web back at $AFTER replicas" || bad "app/web at ${AFTER:-0} replicas"
# Leave the Deployment as it was, whatever happened.
kubectl -n app scale deploy/web --replicas="$BEFORE" >/dev/null 2>&1

summary
