#!/usr/bin/env bash
# Prove the edge: a global external Application Load Balancer in front of
# private GKE, with Cloud Armor in the path.
#
#   Serve      GET / through the anycast IP returns 200 from a pod on a private
#              node
#   WAF        SQL injection, XSS and path traversal probes get 403 at the edge
#              and never reach the pod
#   Rate       a burst over the per-IP limit gets 429s
#   Logged     the denials appear in the load balancer log with the policy and
#              rule that enforced them
#
# Needs make deploy-workload and make deploy-edge. The first run waits for the
# load balancer to program (usually 5 to 10 minutes).
#
#   scripts/test-edge.sh --teardown   delete the Ingress and wait for the
#                                     controller to remove the load balancer.
#                                     Run before destroying edge/ or workload/,
#                                     or the controller's resources are orphaned.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$SA"

PROJECT="$(tfout workload project_id)"
CLUSTER="$(tfjson workload cluster)"
REGISTRY="$(tfout workload registry)"
K8S="$ROOT/workload/k8s"
gcloud container clusters get-credentials "$(jq -r .name <<<"$CLUSTER")" --zone="$(jq -r .location <<<"$CLUSTER")" --project="$PROJECT" --dns-endpoint >/dev/null 2>&1 ||
	{ echo "could not reach the cluster" >&2; exit 1; }

lb_leftovers() {
	gcloud compute forwarding-rules list --global --project="$PROJECT" --filter="name~^k8s2-" --format="value(name)" 2>/dev/null
	gcloud compute backend-services list --global --project="$PROJECT" --filter="name~^k8s1-|name~^k8s2-" --format="value(name)" 2>/dev/null
}

if [ "${1:-}" = "--teardown" ]; then
	section "Edge teardown"
	kubectl -n app delete ingress web --ignore-not-found --wait=true --timeout=600s >/dev/null 2>&1 && ok "Ingress deleted" || bad "Ingress delete did not finish"
	SECONDS=0
	while [ "$SECONDS" -lt 600 ] && [ -n "$(lb_leftovers)" ]; do sleep 15; done
	[ -z "$(lb_leftovers)" ] && ok "controller removed the load balancer (${SECONDS}s)" || bad "load balancer resources remain" "$(lb_leftovers | tr '\n' ' ')"
	kubectl -n app delete -f "$K8S/40-edge.yaml" --ignore-not-found >/dev/null 2>&1 || true
	summary
	exit $?
fi

ADDR_NAME="$(tfjson edge address | jq -r .name)"
IP="$(tfjson edge address | jq -r .ip)"
POLICY="$(tfout edge security_policy)"
[ -n "$IP" ] && [ "$IP" != "null" ] || { echo "edge/ not deployed; make deploy-edge" >&2; exit 1; }

section "Deploy behind the edge"
kubectl apply -f "$K8S/00-namespaces.yaml" >/dev/null
VPCS="$(tfjson network vpcs)"
PSA_RANGE="$(jq -r '[.[] | select(.restricted and .env == "prod")][0].psa_range' <<<"$VPCS")"
PSA_RANGE="$PSA_RANGE" PSC_IP="10.3.255.254" envsubst '${PSA_RANGE} ${PSC_IP}' <"$K8S/10-netpol.yaml" | kubectl apply -f - >/dev/null
WEB_IMAGE="$("$ROOT/scripts/sign-image.sh" "$REGISTRY/nginxinc/nginx-unprivileged:1.27-alpine")"
[ -n "$WEB_IMAGE" ] && ok "web image attested" || { bad "could not sign the web image"; summary; exit 1; }
ADDRESS_NAME="$ADDR_NAME" SECURITY_POLICY="$POLICY" WEB_IMAGE="$WEB_IMAGE" \
	envsubst '${ADDRESS_NAME} ${SECURITY_POLICY} ${WEB_IMAGE}' <"$K8S/40-edge.yaml" | kubectl apply -f - >/dev/null &&
	ok "web, BackendConfig, Service, Ingress, NetworkPolicy applied" || bad "apply failed"
kubectl -n app rollout status deploy/web --timeout=180s >/dev/null 2>&1 && ok "2 web pods ready on private nodes" || bad "web pods not ready"

code() { curl -s -o /dev/null -m 10 -w '%{http_code}' "$@"; }

section "Serve through the anycast IP"
C=""
SECONDS=0
while [ "$SECONDS" -lt 1200 ]; do
	C="$(code "http://$IP/")"
	[ "$C" = "200" ] && break
	sleep 20
done
[ "$C" = "200" ] && ok "GET http://<edge-ip>/ -> 200 after ${SECONDS}s of programming" || { bad "edge never served 200 (last $C)"; summary; exit 1; }
BS="$(gcloud compute backend-services list --global --project="$PROJECT" --filter="securityPolicy~$POLICY" --format="value(name)" 2>/dev/null | head -1)"
[ -n "$BS" ] && ok "Cloud Armor $POLICY attached to backend $BS" || bad "no backend service carries $POLICY"
# Let the policy finish propagating to every front end before asserting denials.
sleep 30

section "WAF at the edge"
START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for probe in "sqli|/?id=1%27%20OR%20%271%27%3D%271" "xss|/?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E" "lfi|/?file=..%2F..%2F..%2Fetc%2Fpasswd"; do
	name="${probe%%|*}"
	path="${probe#*|}"
	C="$(code "http://$IP$path")"
	[ "$C" = "403" ] && ok "$name probe -> 403" || bad "$name probe -> $C (expected 403)"
done
C="$(code "http://$IP/?q=hello")"
[ "$C" = "200" ] && ok "benign query -> 200 (no false positive)" || bad "benign query -> $C"

section "Per-IP rate limit"
# gcloud returns this as an object or a one-element array depending on version.
LIMIT="$(gcloud compute security-policies describe "$POLICY" --project="$PROJECT" --format=json 2>/dev/null |
	jq -r '(if type == "array" then .[0] else . end).rules[] | select(.priority == 2000) | .rateLimitOptions.rateLimitThreshold.count')"
[ -n "$LIMIT" ] && [ "$LIMIT" -gt 0 ] 2>/dev/null || { bad "could not read the rate limit from $POLICY"; LIMIT=0; }
BURST=$((LIMIT * 3))
CODES="$(for _ in $(seq 1 "$BURST"); do code "http://$IP/"; echo; done | sort | uniq -c | tr '\n' ' ')"
N429="$(awk '{for (i = 1; i < NF; i += 2) if ($(i + 1) == "429") print $i}' <<<"$CODES")"
[ "$LIMIT" -gt 0 ] && [ "${N429:-0}" -gt 0 ] && ok "$BURST requests at a $LIMIT/min limit: $CODES" || bad "no 429 in a $BURST request burst ($CODES)"

section "Denials logged with the enforcing rule"
LOG=""
SECONDS=0
while [ "$SECONDS" -lt 300 ]; do
	LOG="$(gcloud logging read "resource.type=\"http_load_balancer\" AND jsonPayload.enforcedSecurityPolicy.outcome=\"DENY\" AND timestamp>=\"$START\"" --project="$PROJECT" --limit=200 --format=json 2>/dev/null)"
	[ "$(jq length <<<"${LOG:-[]}")" -gt 3 ] && break
	sleep 20
done
if [ "$(jq length <<<"${LOG:-[]}")" -gt 0 ]; then
	ok "$(jq -r '[.[].jsonPayload.enforcedSecurityPolicy | "\(.priority):\(.configuredAction)"] | group_by(.) | map("\(.[0]) x\(length)") | join(", ")' <<<"$LOG") in the LB log"
else
	bad "no DENY entries in the load balancer log within 300s"
fi

summary
