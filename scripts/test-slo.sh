#!/usr/bin/env bash
# Prove the SLO and its burn-rate page on orders-api (Cloud Run).
#
#   Baseline  steady authenticated load at 0% fault: the SLI has data, no page
#   Fault     a new revision with FAULT_PERCENT=50 (burn rate about 50x on a
#             99% SLO): lz-slo-orders-api-fast-burn opens, timed from the
#             moment the faulty revision took traffic
#   Recover   FAULT_PERCENT=0 again: the short window clears and the page
#             closes, timed
#
# Needs make deploy-slo twice (identities, then after make build-orders).
# About 25 to 35 minutes, almost all of it waiting on the windows.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

BASELINE="${BASELINE:-300}"
POLL="${POLL_SECONDS:-1500}"
S="$(tfjson slo service)"
[ -n "$S" ] && [ "$S" != "null" ] || { echo "slo/ has no deployed service; make build-orders, then make deploy-slo" >&2; exit 1; }
PROJECT="$(jq -r .project <<<"$S")"
REGION="$(jq -r .region <<<"$S")"
URL="$(jq -r .uri <<<"$S")"
SLO="$(jq -r .slo <<<"$S")"
PAGE="$(jq -r .policies["fast-burn"] <<<"$S")"
SEED="$(tfout bootstrap seed_project_id)"
WORK="$(mktemp -d)"
trap 'touch "$WORK/stop"; wait 2>/dev/null; rm -rf "$WORK"' EXIT

api() { curl -s -H "Authorization: Bearer $(gcloud auth print-access-token "$IMP" 2>/dev/null)" -H "x-goog-user-project: $SEED" "$@"; }
alert() { # $1 = open|closed, $2 = since
	api -G "https://monitoring.googleapis.com/v3/projects/$PROJECT/alerts" \
		--data-urlencode "filter=policy.display_name=\"$PAGE\" AND open_time>=\"$2\"" | jq -c --arg st "$1" '[.alerts[]? | select(.state | ascii_downcase == $st)][0] // empty'
}
fault() { gcloud run services update orders-api --region="$REGION" --project="$PROJECT" --update-env-vars="FAULT_PERCENT=$1" --quiet "$IMP" >/dev/null 2>&1; }

# About 5 requests a second until the stop file appears, one status code per line.
load() {
	local tok t=0
	tok="$(gcloud auth print-identity-token "$IMP" --audiences="$URL" --include-email 2>/dev/null)"
	while [ ! -f "$WORK/stop" ]; do
		for _ in 1 2 3 4 5; do curl -s -o /dev/null -m 5 -w '%{http_code}\n' -H "Authorization: Bearer $tok" "$URL/api/orders" >>"$WORK/codes" & done
		sleep 1
		t=$((t + 1))
		# Identity tokens last an hour; refresh well before.
		[ $((t % 1800)) = 0 ] && tok="$(gcloud auth print-identity-token "$IMP" --audiences="$URL" --include-email 2>/dev/null)"
	done
	wait
}
tally() { sort "$WORK/codes" | uniq -c | awk '{printf "%s x%s ", $2, $1}'; : >"$WORK/codes"; }

section "Baseline"
fault 0 && ok "FAULT_PERCENT=0" || bad "could not set FAULT_PERCENT=0"
load &
sleep "$BASELINE"
echo "        baseline ${BASELINE}s: $(tally)"
[ -z "$(alert open "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)")" ] && ok "no page open at baseline" || bad "a page is already open"

section "Inject a 50% fault"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
T0=$(date +%s)
fault 50 && ok "new revision with FAULT_PERCENT=50 serving after $(($(date +%s) - T0))s" || bad "could not inject the fault"
T0=$(date +%s)
OPEN=""
while [ $(($(date +%s) - T0)) -lt "$POLL" ]; do
	OPEN="$(alert open "$START")"
	[ -n "$OPEN" ] && break
	sleep 30
done
[ -n "$OPEN" ] && ok "$PAGE opened $(($(date +%s) - T0))s after the fault (load: $(tally))" || bad "no page within ${POLL}s (load: $(tally))"
BUDGET="$(api -G "https://monitoring.googleapis.com/v3/projects/$PROJECT/timeSeries" \
	--data-urlencode "filter=select_slo_budget_fraction(\"$SLO\")" \
	--data-urlencode "interval.endTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
	--data-urlencode "interval.startTime=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '-5 minutes' +%Y-%m-%dT%H:%M:%SZ)" |
	jq -r '.timeSeries[0].points[0].value.doubleValue // empty')"
[ -n "$BUDGET" ] && echo "        error budget remaining: $(awk -v b="$BUDGET" 'BEGIN{printf "%.1f%%", b*100}')"

section "Remove the fault"
fault 0 && ok "FAULT_PERCENT=0 again" || bad "could not remove the fault"
T1=$(date +%s)
CLOSED=""
while [ $(($(date +%s) - T1)) -lt "$POLL" ]; do
	CLOSED="$(alert closed "$START")"
	[ -n "$CLOSED" ] && break
	sleep 30
done
[ -n "$CLOSED" ] && ok "page closed $(($(date +%s) - T1))s after the fault was removed" || bad "page still open after ${POLL}s"
touch "$WORK/stop"
wait
summary
