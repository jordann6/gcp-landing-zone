#!/usr/bin/env bash
# Prove the paved road: admission, identity, segmentation, encryption, and
# failover, on the live cluster and database.
#
# Needs make deploy-workload. The failover check restarts the primary onto its
# standby zone; it takes about a minute and is skipped with SKIP_FAILOVER=1.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

PROJECT="$(tfout workload project_id)"
CLUSTER="$(tfjson workload cluster)"
C_NAME="$(jq -r .name <<<"$CLUSTER")"
C_ZONE="$(jq -r .location <<<"$CLUSTER")"
SQL="$(tfjson workload sql)"
DB="$(jq -r .primary <<<"$SQL")"
DB_IP="$(jq -r .private_ip <<<"$SQL")"
REPLICA="$(jq -r '.replica // empty' <<<"$SQL")"
REGISTRY="$(tfout workload registry)"
VPCS="$(tfjson network vpcs)"
PSA_RANGE="$(jq -r '[.[] | select(.restricted and .env == "prod")][0].psa_range' <<<"$VPCS")"
PSC_IP="10.3.255.254"
K8S="$ROOT/workload/k8s"

section "Cluster access (DNS endpoint, IAM-authenticated, no IP allowlist)"
if gcloud container clusters get-credentials "$C_NAME" --zone="$C_ZONE" --project="$PROJECT" --dns-endpoint >/dev/null 2>&1 &&
	kubectl get nodes >/dev/null 2>&1; then
	ok "kubectl reaches the private cluster through the DNS endpoint"
else
	bad "could not reach the cluster through the DNS endpoint"
	summary
	exit 1
fi

PRIV="$(gcloud container clusters describe "$C_NAME" --zone="$C_ZONE" --project="$PROJECT" --format=json)"
jq -e '.privateClusterConfig.enablePrivateNodes == true' >/dev/null <<<"$PRIV" && ok "private nodes" || bad "nodes are not private"
jq -e '.databaseEncryption.state == "ENCRYPTED"' >/dev/null <<<"$PRIV" && ok "etcd secrets envelope-encrypted with Cloud KMS" || bad "application-layer secrets encryption off"
jq -e '.networkConfig.datapathProvider == "ADVANCED_DATAPATH"' >/dev/null <<<"$PRIV" && ok "Dataplane V2 (native NetworkPolicy)" || bad "Dataplane V2 off"
jq -e '.workloadIdentityConfig.workloadPool != null' >/dev/null <<<"$PRIV" && ok "Workload Identity pool set" || bad "no Workload Identity"

section "Kubernetes baseline"
kubectl apply -f "$K8S/00-namespaces.yaml" >/dev/null
PSA_RANGE="$PSA_RANGE" PSC_IP="$PSC_IP" envsubst '${PSA_RANGE} ${PSC_IP}' <"$K8S/10-netpol.yaml" | kubectl apply -f - >/dev/null &&
	ok "default-deny NetworkPolicy applied in app/" || bad "NetworkPolicy apply failed"

# kubectl run with the restricted Pod Security Standard's required fields, so a
# rejection below is Binary Authorization or NetworkPolicy, not PSA.
restricted_pod() {
	jq -cn --arg img "$1" --argjson cmd "$2" '{spec: {
		securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: "RuntimeDefault"}},
		containers: [{name: "c", image: $img, command: $cmd,
			securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}]}}'
}
sh_cmd() { jq -cn --arg s "$1" '["sh", "-c", $s]'; }

section "Admission: Binary Authorization"
PG_TAG="$REGISTRY/library/postgres:16-alpine"
SDK_TAG="$REGISTRY/google/cloud-sdk:slim"
expect_denied "unsigned image rejected at admission" "Binary Authorization|denied by|attestation" \
	kubectl -n app run unsigned-"$(date +%s)" --image="$PG_TAG" --restart=Never \
	--overrides="$(restricted_pod "$PG_TAG" '["true"]')"

PG_IMAGE="$("$ROOT/scripts/sign-image.sh" "$PG_TAG")" && SDK_IMAGE="$("$ROOT/scripts/sign-image.sh" "$SDK_TAG")"
if [ -n "${PG_IMAGE:-}" ] && [ -n "${SDK_IMAGE:-}" ]; then
	ok "digests attested with the KMS-backed attestor"
else
	bad "could not sign images"
fi

section "Paved road end to end: Workload Identity -> Secret Manager -> Cloud SQL over TLS"
kubectl -n app delete job db-check --ignore-not-found >/dev/null 2>&1
PROJECT="$PROJECT" DB_IP="$DB_IP" PG_IMAGE="$PG_IMAGE" SDK_IMAGE="$SDK_IMAGE" \
	envsubst '${PROJECT} ${DB_IP} ${PG_IMAGE} ${SDK_IMAGE}' <"$K8S/20-db-check.yaml" | kubectl apply -f - >/dev/null
if kubectl -n app wait --for=condition=complete job/db-check --timeout=300s >/dev/null 2>&1; then
	LINE="$(kubectl -n app logs job/db-check -c psql 2>/dev/null | tail -1)"
	[ "$LINE" = "connected over tls" ] && ok "app pod read its secret with no key and connected over TLS" || bad "unexpected result: $LINE"
else
	bad "db-check job did not complete" "$(kubectl -n app logs job/db-check --all-containers 2>&1 | tail -5)"
fi

section "Segmentation"
# A pod in app/ without tier=app: NetworkPolicy denies it the database.
NOLABEL="$(kubectl -n app run seg-"$(date +%s)" --image="$PG_IMAGE" --restart=Never --rm -i --quiet \
	--overrides="$(restricted_pod "$PG_IMAGE" "$(sh_cmd "timeout 8 nc -z $DB_IP 5432 && echo open || echo blocked")")" 2>/dev/null | tail -1)"
[ "$NOLABEL" = "blocked" ] && ok "pod without tier=app cannot reach Cloud SQL (NetworkPolicy)" || bad "unlabelled pod reached Cloud SQL ($NOLABEL)"

PROBE="$(tfjson network probe)"
if [ -n "$PROBE" ] && [ "$PROBE" != "null" ]; then
	R="$(gcloud compute ssh "$(jq -r .name <<<"$PROBE")" --zone="$(jq -r .zone <<<"$PROBE")" --project="$(jq -r .project <<<"$PROBE")" \
		--tunnel-through-iap --quiet --command="timeout 8 bash -c '</dev/tcp/$DB_IP/5432' && echo open || echo blocked" 2>/dev/null | tail -1)"
	[ "$R" = "blocked" ] && ok "probe VM in the same VPC cannot reach Cloud SQL (firewall policy)" || bad "probe reached Cloud SQL ($R)"
else
	skip "VM-level segmentation (probe not deployed)"
fi

section "Data tier"
DBJ="$(gcloud sql instances describe "$DB" --project="$PROJECT" "$IMP" --format=json)"
jq -e '[.ipAddresses[].type] | all(. == "PRIVATE")' >/dev/null <<<"$DBJ" && ok "Cloud SQL has private IP only" || bad "Cloud SQL has a non-private address"
jq -e '.diskEncryptionConfiguration.kmsKeyName != null' >/dev/null <<<"$DBJ" && ok "Cloud SQL encrypted with CMEK" || bad "Cloud SQL not on CMEK"
jq -e '.settings.availabilityType == "REGIONAL"' >/dev/null <<<"$DBJ" && ok "Cloud SQL is regional HA" || bad "Cloud SQL is not HA"
jq -e '.settings.backupConfiguration.pointInTimeRecoveryEnabled == true' >/dev/null <<<"$DBJ" && ok "PITR enabled" || bad "PITR off"
if [ -n "$REPLICA" ]; then
	RJ="$(gcloud sql instances describe "$REPLICA" --project="$PROJECT" "$IMP" --format=json)"
	jq -e '.state == "RUNNABLE" and .instanceType == "READ_REPLICA_INSTANCE"' >/dev/null <<<"$RJ" &&
		ok "cross-region replica running in $(jq -r .region <<<"$RJ")" || bad "replica not running"
fi

if [ "${SKIP_FAILOVER:-0}" != "1" ]; then
	section "Failover (zonal HA)"
	Z1="$(jq -r .gceZone <<<"$DBJ")"
	T0=$(date +%s)
	if gcloud sql instances failover "$DB" --project="$PROJECT" "$IMP" --quiet >/dev/null 2>&1; then
		Z2="$(gcloud sql instances describe "$DB" --project="$PROJECT" "$IMP" --format='value(gceZone)')"
		T1=$(date +%s)
		[ "$Z1" != "$Z2" ] && ok "failed over $Z1 -> $Z2 in $((T1 - T0))s, same private IP" || bad "zone did not change ($Z1)"
	else
		bad "failover command failed"
	fi
fi

summary
