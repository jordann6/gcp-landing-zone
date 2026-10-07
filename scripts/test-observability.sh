#!/usr/bin/env bash
# Prove the ops alerting on live resources (needs make deploy-observability and
# make deploy-network; the VM and Cloud SQL policies only evaluate with those up).
#
#   Scope      the logging project's metrics scope reads the app and host projects
#   Policies   every ops alert policy the root created exists and is enabled
#   Channel    the ops channel is wired to the policies (delivery is not testable
#              from here: Monitoring exposes no send receipt for email)
#   End to end force a firewall-deny spike from the probe VM and wait for the
#              Monitoring alert (an incident) to open, then report it
#
# Reads go through sa-terraform: the operator holds no Monitoring role in the
# logging project, by design.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

POLL_SECONDS="${POLL_SECONDS:-900}"

TOKEN="$(gcloud auth print-access-token "$IMP" 2>/dev/null)"
api() { curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $(tfout bootstrap seed_project_id)" "$@"; }

SCOPE="$(tfjson observability metrics_scope)"
if [ -z "$SCOPE" ] || [ "$SCOPE" = "null" ]; then
	echo "observability/ has no metrics_scope output; run make deploy-observability first" >&2
	exit 1
fi
LOGGING="$(jq -r .scoping_project <<<"$SCOPE")"

section "Metrics scope"
SCOPE_JSON="$(api "https://monitoring.googleapis.com/v1/locations/global/metricsScopes/${LOGGING}")"
# The API reports project numbers, so map each monitored ID to its number.
for key in app host; do
	P="$(jq -r ".monitored.${key}" <<<"$SCOPE")"
	NUM="$({ tfjson terraform app_projects; tfjson terraform host_projects; } 2>/dev/null | jq -rs --arg p "$P" '[.[][] | select(.project_id == $p) | .number][0] // empty')"
	[ -z "$NUM" ] && NUM="$(gcloud projects describe "$P" --format='value(projectNumber)' "$IMP" 2>/dev/null)"
	jq -e --arg n "$NUM" '[.monitoredProjects[]?.name | split("/") | last] | index($n) != null' <<<"$SCOPE_JSON" >/dev/null 2>&1 &&
		ok "$LOGGING scope reads $P ($NUM)" || bad "$LOGGING scope does not read $P ($NUM)" "${SCOPE_JSON:0:200}"
done

section "Alert policies"
POLICIES="$(api "https://monitoring.googleapis.com/v3/projects/${LOGGING}/alertPolicies?pageSize=200")"
EXPECTED="$(tfjson observability alert_policies)"
CHANNEL="$(tfjson observability ops_channel | jq -r .)"
while read -r name; do
	jq -e --arg n "$name" '.alertPolicies[]? | select(.displayName == $n and .enabled == true)' <<<"$POLICIES" >/dev/null 2>&1 &&
		ok "$name exists and is enabled" || bad "$name missing or disabled"
done < <(jq -r '.[]' <<<"$EXPECTED")
if [ -n "$CHANNEL" ] && [ "$CHANNEL" != "null" ]; then
	N="$(jq --arg c "$CHANNEL" '[.alertPolicies[]? | select(.displayName | startswith("lz-ops-")) | select(.notificationChannels // [] | index($c))] | length' <<<"$POLICIES")"
	T="$(jq '[.alertPolicies[]? | select(.displayName | startswith("lz-ops-"))] | length' <<<"$POLICIES")"
	[ "$N" = "$T" ] && [ "$T" != "0" ] && ok "all $T ops policies notify the ops channel" || bad "ops channel on $N of $T ops policies"
else
	skip "no ops channel (ops_alert_email empty): policies have no recipient"
fi

section "End to end: force the firewall-deny spike alert"
POLICY="lz-ops-ngfw-egress-deny-spike"
PROBE="$(tfjson network probe 2>/dev/null)"
if [ -z "$PROBE" ] || [ "$PROBE" = "null" ]; then
	skip "no probe VM (make deploy-network)"
else
	P_NAME="$(jq -r .name <<<"$PROBE")"
	P_ZONE="$(jq -r .zone <<<"$PROBE")"
	P_PROJ="$(jq -r .project <<<"$PROBE")"
	START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	# Denied destinations, repeated: the FQDN allowlist denies example.com
	# (proven in make test), and every attempt is a logged egress deny.
	gcloud compute ssh "$P_NAME" --zone="$P_ZONE" --project="$P_PROJ" --tunnel-through-iap --quiet \
		--command='for i in $(seq 1 60); do curl -s -m 2 -o /dev/null https://example.com || true; done' >/dev/null 2>&1
	echo "        forced 60 denied egress attempts at $START, polling up to ${POLL_SECONDS}s"
	ALERT=""
	for _ in $(seq 1 $((POLL_SECONDS / 30))); do
		ALERT="$(api -G "https://monitoring.googleapis.com/v3/projects/${LOGGING}/alerts" \
			--data-urlencode "filter=policy.display_name=\"${POLICY}\" AND open_time>=\"${START}\"" |
			jq -c '.alerts[0] // empty')"
		[ -n "$ALERT" ] && break
		sleep 30
	done
	if [ -n "$ALERT" ]; then
		ok "$POLICY opened an alert: $(jq -r '"\(.name | split("/") | last) state=\(.state) opened=\(.openTime)"' <<<"$ALERT")"
	else
		bad "$POLICY did not open an alert within ${POLL_SECONDS}s" \
			"check the firewall log entries (compute.googleapis.com/firewall) and the lz-ngfw-egress-deny log metric in the host project"
	fi
fi

summary
