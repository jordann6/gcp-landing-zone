#!/usr/bin/env bash
# Prove the incident wiring on live resources (needs make deploy-incident with
# the image built, make deploy-compute, deploy-workload and deploy-network).
#
#   Private     ingress is internal-only, no public invoker, a direct call from
#               this workstation is refused
#   Firewall    binding the quarantine secure tag to the probe VM cuts its egress
#               (the same rule the handler relies on), and unbinding restores it
#   SCC path    a sample finding published to the scc-findings topic reaches the
#               handler, which decides on the management VM; an ineligible
#               finding is skipped
#   Ops path    sample Monitoring incidents reach the handler: GKE node-not-ready
#               and Cloud SQL down, plus a closed incident that must do nothing
#   Live mode   only when the handler runs with dry_run=false (terraform apply
#               -var dry_run=false in incident/): the VM is really quarantined
#               (tag, label, snapshot, stopped, service account detached), then
#               restored. Cloud SQL failover stays dry unless the handler is also applied with -var sql_failover_live=true.
#
# SCC itself is not activated (console-only), so the finding is published to the
# topic the SCC notification config would publish to. Everything downstream of
# the topic is the real path. Runs through sa-terraform: the operator holds no
# role in the logging project, by design.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

POLL_SECONDS="${POLL_SECONDS:-420}"
H="$(tfjson incident handler)"
if [ -z "$H" ] || [ "$H" = "null" ]; then
	echo "incident/ has no handler output; run make build-incident then make deploy-incident" >&2
	exit 1
fi
LOGGING="$(jq -r .project <<<"$H")"
REGION="$(jq -r .region <<<"$H")"
SVC="$(jq -r .name <<<"$H")"
URI="$(jq -r .uri <<<"$H")"
SCC_TOPIC="$(jq -r .scc_topic <<<"$H" | sed 's|.*/||')"
OPS_TOPIC="$(tfout incident ops_topic | sed 's|.*/||')"
DRY="$(jq -r .dry_run <<<"$H")"

VM="$(tfjson compute management_vm)"
V_NAME="$(jq -r .name <<<"$VM")"
V_ZONE="$(jq -r .zone <<<"$VM")"
V_PROJ="$(jq -r .project <<<"$VM")"
V_NUM="$(gcloud projects describe "$V_PROJ" --format='value(projectNumber)' "$IMP")"

echo "handler $SVC dry_run=$DRY"

publish() { gcloud pubsub topics publish "$1" --project="$LOGGING" --message="$2" "$IMP" >/dev/null 2>&1; }

# wait_log <jq-selector over jsonPayload> : prints the first matching entry
wait_log() {
	local filter="$1" since="$2" out
	for _ in $(seq 1 $((POLL_SECONDS / 10))); do
		out="$(gcloud logging read "resource.type=\"cloud_run_revision\" AND resource.labels.service_name=\"$SVC\" AND timestamp>=\"$since\" AND $filter" \
			--project="$LOGGING" --limit=1 --format=json "$IMP" 2>/dev/null | jq -c '.[0].jsonPayload // empty')"
		[ -n "$out" ] && { echo "$out"; return 0; }
		sleep 10
	done
	return 1
}

section "Private by construction"
SVC_JSON="$(gcloud run services describe "$SVC" --region="$REGION" --project="$LOGGING" --format=json "$IMP" 2>/dev/null)"
INGRESS="$(jq -r '.metadata.annotations["run.googleapis.com/ingress"] // empty' <<<"$SVC_JSON")"
[ "$INGRESS" = "internal" ] && ok "ingress is internal-only" || bad "ingress is '$INGRESS', want internal" "${SVC_JSON:0:200}"
POLICY="$(gcloud run services get-iam-policy "$SVC" --region="$REGION" --project="$LOGGING" --format=json "$IMP" 2>/dev/null)"
if jq -e '[.bindings[]?.members[]?] | any(. == "allUsers" or . == "allAuthenticatedUsers")' <<<"$POLICY" >/dev/null 2>&1; then
	bad "service grants a public principal" "$POLICY"
else
	ok "no allUsers / allAuthenticatedUsers on the service"
fi
INVOKERS="$(jq -r '[.bindings[]? | select(.role == "roles/run.invoker") | .members[]] | join(",")' <<<"$POLICY")"
[ "$INVOKERS" = "serviceAccount:sa-incident-invoker@${LOGGING}.iam.gserviceaccount.com" ] && ok "only the push identity can invoke" || bad "invokers: $INVOKERS"
CODE="$(curl -s -m 15 -o /dev/null -w '%{http_code}' -X POST "$URI/scc" -d '{}')"
case "$CODE" in 403 | 404) ok "direct call from the workstation refused (HTTP $CODE)" ;; *) bad "direct call returned HTTP $CODE, want 403/404" ;; esac

section "Quarantine firewall rule (secure tag on the probe VM)"
PROBE="$(tfjson network probe 2>/dev/null)"
TAGVAL="$(tfout incident quarantine_tag_value)"
# gcloud takes the namespaced name (host project/key/value); the API takes tagValues/ID.
TAGNS="$(tfjson network vpcs | jq -r '[.[] | select(.restricted)][0].project')/lz-quarantine/isolated"
if [ -z "$PROBE" ] || [ "$PROBE" = "null" ]; then
	skip "no probe VM (make deploy-network)"
else
	P_NAME="$(jq -r .name <<<"$PROBE")"
	P_ZONE="$(jq -r .zone <<<"$PROBE")"
	P_PROJ="$(jq -r .project <<<"$PROBE")"
	P_NUM="$(gcloud projects describe "$P_PROJ" --format='value(projectNumber)' "$IMP")"
	P_ID="$(gcloud compute instances describe "$P_NAME" --zone="$P_ZONE" --project="$P_PROJ" --format='value(id)' "$IMP")"
	P_PARENT="//compute.googleapis.com/projects/${P_NUM}/zones/${P_ZONE}/instances/${P_ID}"
	reach() {
		gcloud compute ssh "$P_NAME" --zone="$P_ZONE" --project="$P_PROJ" --tunnel-through-iap --quiet \
			--command="curl -s -m 8 -o /dev/null -w '%{http_code}' https://storage.googleapis.com/ || true" 2>/dev/null | tail -1
	}
	unbind() { gcloud resource-manager tags bindings delete --tag-value="$TAGNS" --parent="$P_PARENT" --location="$P_ZONE" "$IMP" >/dev/null 2>&1; }
	trap unbind EXIT
	BEFORE="$(reach)"
	[ -n "$BEFORE" ] && [ "$BEFORE" != "000" ] && ok "before the tag: Google APIs reachable from the probe (HTTP $BEFORE)" || bad "before the tag: probe cannot reach the PSC endpoint (HTTP '$BEFORE'); the control would prove nothing"
	if BIND_ERR="$(gcloud resource-manager tags bindings create --tag-value="$TAGNS" --parent="$P_PARENT" --location="$P_ZONE" "$IMP" 2>&1)"; then
		ok "secure tag bound to the probe VM"
		sleep 20
		AFTER="$(reach)"
		[ "$AFTER" = "000" ] && ok "with the tag: egress cut (SSH over IAP still works, the org allow is final)" || bad "with the tag: probe still reached the endpoint (HTTP '$AFTER')"
		unbind
		sleep 20
		RESTORED="$(reach)"
		[ -n "$RESTORED" ] && [ "$RESTORED" != "000" ] && ok "tag removed: egress restored" || bad "tag removed but egress still cut (HTTP '$RESTORED')"
	else
		bad "could not bind the secure tag" "$BIND_ERR"
	fi
	trap - EXIT
fi

section "SCC path: sample finding to $SCC_TOPIC"
T0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FID="lz-test-finding-$(date +%s)"
V_ID="$(gcloud compute instances describe "$V_NAME" --zone="$V_ZONE" --project="$V_PROJ" --format='value(id)' "$IMP")"
RES="//compute.googleapis.com/projects/${V_NUM}/zones/${V_ZONE}/instances/${V_NAME}"
publish "$SCC_TOPIC" "{\"notificationConfigName\":\"test\",\"finding\":{\"name\":\"$FID\",\"category\":\"LZ_TEST\",\"severity\":\"HIGH\",\"state\":\"ACTIVE\",\"resourceName\":\"$RES\"}}" || bad "publish to $SCC_TOPIC failed"
if OUT="$(wait_log "jsonPayload.event=\"handled\" AND jsonPayload.finding=\"$FID\"" "$T0")"; then
	ok "handler quarantine decision: $(jq -c '{steps, dry_run}' <<<"$OUT")"
	if [ "$DRY" = "true" ]; then
		[ "$(jq -r '.dry_run' <<<"$OUT")" = "true" ] && ok "dry-run: the VM was left alone" || bad "dry_run flag disagrees with the deployed setting"
		STATUS="$(gcloud compute instances describe "$V_NAME" --zone="$V_ZONE" --project="$V_PROJ" --format='value(status)' "$IMP")"
		[ "$STATUS" = "RUNNING" ] && ok "management VM still RUNNING" || bad "management VM is $STATUS after a dry run"
	fi
else
	bad "no handler decision for $FID within ${POLL_SECONDS}s" "gcloud logging read on service $SVC in $LOGGING; check the push subscription incident-scc"
fi

T1="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
publish "$SCC_TOPIC" "{\"finding\":{\"name\":\"lz-test-other\",\"state\":\"ACTIVE\",\"resourceName\":\"//compute.googleapis.com/projects/${V_NUM}/zones/${V_ZONE}/instances/not-a-real-vm\"}}"
if OUT="$(wait_log "jsonPayload.event=\"skipped\" AND jsonPayload.route=\"/scc\"" "$T1")"; then
	ok "finding for another VM was not acted on: $(jq -r .reason <<<"$OUT" | cut -c1-90)"
else
	bad "no skip recorded for the ineligible finding"
fi

if [ "$DRY" = "false" ]; then
	section "Live quarantine result on $V_NAME"
	INST="$(gcloud compute instances describe "$V_NAME" --zone="$V_ZONE" --project="$V_PROJ" --format=json "$IMP")"
	[ "$(jq -r '.labels.quarantine // empty' <<<"$INST")" = "true" ] && ok "labeled quarantine=true" || bad "label missing"
	[ "$(jq -r .status <<<"$INST")" = "TERMINATED" ] && ok "instance stopped" || bad "instance is $(jq -r .status <<<"$INST")"
	[ "$(jq -r '.serviceAccounts // [] | length' <<<"$INST")" = "0" ] && ok "service account detached" || bad "service account still attached"
	SNAPS="$(gcloud compute snapshots list --project="$V_PROJ" --filter="labels.source-instance=$V_NAME" --format='value(name)' "$IMP")"
	[ -n "$SNAPS" ] && ok "disk snapshot taken: $SNAPS" || bad "no snapshot labeled source-instance=$V_NAME"
	PARENT="//compute.googleapis.com/projects/${V_NUM}/zones/${V_ZONE}/instances/${V_ID}"
	BOUND="$(gcloud resource-manager tags bindings list --parent="$PARENT" --location="$V_ZONE" --format='value(tagValue)' "$IMP")"
	grep -q "$TAGVAL" <<<"$BOUND" && ok "quarantine secure tag bound" || bad "tag not bound ($BOUND)"

	section "Restore $V_NAME"
	gcloud resource-manager tags bindings delete --tag-value="$TAGNS" --parent="$PARENT" --location="$V_ZONE" "$IMP" >/dev/null 2>&1 && ok "tag unbound" || bad "tag unbind failed"
	gcloud compute instances remove-labels "$V_NAME" --labels=quarantine --zone="$V_ZONE" --project="$V_PROJ" "$IMP" >/dev/null 2>&1 && ok "label removed" || bad "label removal failed"
	gcloud compute instances set-service-account "$V_NAME" --zone="$V_ZONE" --project="$V_PROJ" \
		--service-account="sa-mgmt-vm@${V_PROJ}.iam.gserviceaccount.com" --scopes=cloud-platform "$IMP" >/dev/null 2>&1 && ok "service account reattached" || bad "service account reattach failed"
	gcloud compute instances start "$V_NAME" --zone="$V_ZONE" --project="$V_PROJ" "$IMP" >/dev/null 2>&1 && ok "instance started" || bad "instance start failed"
	for s in $SNAPS; do
		gcloud compute snapshots delete "$s" --project="$V_PROJ" --quiet "$IMP" >/dev/null 2>&1 && ok "snapshot $s deleted" || bad "snapshot $s not deleted (verify-teardown will flag it)"
	done
fi

section "Ops path: sample Monitoring incidents to $OPS_TOPIC"
inc() { # policy state id resource-labels-json
	printf '{"version":"1.2","incident":{"incident_id":"%s","policy_name":"%s","state":"%s","resource":{"type":"x","labels":%s}}}' "$3" "$1" "$2" "$4"
}
GKE_CLUSTER="$(tfjson workload cluster | jq -r .name)"
SQL_NAME="$(tfjson workload sql | jq -r .primary)"

T2="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IID="lz-test-gke-$(date +%s)"
publish "$OPS_TOPIC" "$(inc lz-ops-gke-node-not-ready open "$IID" "{\"cluster_name\":\"$GKE_CLUSTER\"}")"
if OUT="$(wait_log "jsonPayload.event=\"handled\" AND jsonPayload.incident_id=\"$IID\"" "$T2")"; then
	ok "GKE node-not-ready alert -> $(jq -c '{action, from, to, dry_run}' <<<"$OUT")"
	if [ "$DRY" = "false" ]; then
		# The handler's resize is still an operation on the cluster; retry until it clears.
		BACK=""
		for _ in $(seq 1 20); do
			gcloud container clusters resize "$GKE_CLUSTER" --node-pool=pool-default --num-nodes="$(jq -r .from <<<"$OUT")" \
				--zone="$V_ZONE" --project="$V_PROJ" --quiet "$IMP" >/dev/null 2>&1 && { BACK=1; break; }
			sleep 15
		done
		[ -n "$BACK" ] && ok "node pool scaled back to $(jq -r .from <<<"$OUT")" || bad "scale-back failed; resize pool-default by hand"
	fi
else
	bad "GKE alert produced no decision within ${POLL_SECONDS}s"
fi

T3="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
IID="lz-test-sql-$(date +%s)"
publish "$OPS_TOPIC" "$(inc lz-ops-sql-instance-down open "$IID" "{\"database_id\":\"${V_PROJ}:${SQL_NAME}\"}")"
if OUT="$(wait_log "jsonPayload.incident_id=\"$IID\" AND (jsonPayload.event=\"handled\" OR jsonPayload.event=\"skipped\")" "$T3")"; then
	ok "Cloud SQL down alert -> $(jq -c . <<<"$OUT" | cut -c1-160)"
else
	bad "Cloud SQL alert produced no decision within ${POLL_SECONDS}s"
fi

T4="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
publish "$OPS_TOPIC" "$(inc lz-ops-gke-node-not-ready closed "lz-test-closed" "{}")"
if OUT="$(wait_log "jsonPayload.event=\"skipped\" AND jsonPayload.route=\"/ops\"" "$T4")"; then
	ok "closed incident did nothing: $(jq -r .reason <<<"$OUT")"
else
	bad "closed incident was not skipped"
fi

summary
