#!/usr/bin/env bash
# Prove config history on live resources (needs the terraform/ root applied).
#
#   Feeds    the three org feeds exist
#   Change   grant the operator roles/browser on the logging project, a harmless
#            and fully reverted IAM change
#   Feed     the change reaches the asset-changes Pub/Sub subscription
#   Export   a triggered export lands the same binding in BigQuery
#   Revert   the binding is removed and the removal reaches the feed too
#
# Everything runs as sa-terraform; the operator holds no role in the logging
# project. The change is reverted by a trap even if a check fails.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

POLL_SECONDS="${POLL_SECONDS:-300}"

H="$(tfjson terraform asset_history)"
if [ -z "$H" ] || [ "$H" = "null" ]; then
	echo "terraform/ has no asset_history output; apply the governance root first" >&2
	exit 1
fi
LOGGING="$(tfout terraform logging_project_id)"
# Asset Inventory names projects by number, not ID.
LOGGING_NUM="$(tfout terraform logging_project_number)"
ORG="$(tfout terraform org_id)"
SUB="$(jq -r .subscription <<<"$H")"
JOB="$(jq -r '.export_jobs.iam_policy' <<<"$H")"
OPERATOR="user:$(gcloud config get-value account 2>/dev/null)"
# IAM stores a user in the casing the account was created with, which need not
# match what gcloud prints. Compare lowercase, remove with the stored casing.
OPERATOR_LC="$(tr '[:upper:]' '[:lower:]' <<<"$OPERATOR")"
ROLE="roles/browser"
SEED="$(tfout bootstrap seed_project_id)"
TOKEN="$(gcloud auth print-access-token "$IMP" 2>/dev/null)"

added=0
# stored_member prints the member exactly as IAM holds it, or nothing.
stored_member() {
	gcloud projects get-iam-policy "$LOGGING" "$IMP" --format=json 2>/dev/null |
		jq -r --arg r "$ROLE" --arg m "$OPERATOR_LC" \
			'[.bindings[]? | select(.role == $r) | .members[]? | select(ascii_downcase == $m)][0] // empty'
}
revert() {
	[ "$added" = "1" ] || return 0
	local m
	m="$(stored_member)"
	[ -n "$m" ] && gcloud projects remove-iam-policy-binding "$LOGGING" --member="$m" --role="$ROLE" "$IMP" >/dev/null 2>&1
	# An exit code is not proof: a member in the wrong casing "succeeds" and
	# removes nothing. Check the policy.
	[ -z "$(stored_member)" ] || return 1
	added=0
}
trap revert EXIT

# pull_matches <jq-test>: pull and ack up to 50 messages; print those matching.
pull_matches() {
	gcloud pubsub subscriptions pull "$SUB" --limit=50 --auto-ack "$IMP" --format=json 2>/dev/null |
		jq -r '.[]?.message.data' | while read -r d; do base64 -d <<<"$d" 2>/dev/null; echo; done |
		jq -c "select($1)" 2>/dev/null
}

section "Feeds"
FEEDS="$(curl -s -H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $SEED" \
	"https://cloudasset.googleapis.com/v1/organizations/${ORG}/feeds")"
for f in lz-iam-policy lz-org-policy lz-firewall; do
	jq -e --arg f "$f" '.feeds[]? | select(.name | endswith("/feeds/" + $f))' <<<"$FEEDS" >/dev/null 2>&1 &&
		ok "org feed $f exists" || bad "org feed $f missing" "${FEEDS:0:200}"
done

section "Make a change, find it in the feed"
# Drain anything stale so a match below is this change and nothing older.
pull_matches 'true' >/dev/null
if gcloud projects add-iam-policy-binding "$LOGGING" --member="$OPERATOR" --role="$ROLE" "$IMP" >/dev/null 2>&1; then
	added=1
	ok "granted $OPERATOR $ROLE on $LOGGING"
else
	bad "could not grant the test binding"
	summary
	exit 1
fi

TEST="(.asset.name | endswith(\"/projects/${LOGGING_NUM}\")) and ([.asset.iamPolicy.bindings[]? | select(.role == \"${ROLE}\") | .members[]? | ascii_downcase] | index(\"${OPERATOR_LC}\") != null)"
FOUND=""
deadline=$((SECONDS + POLL_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
	FOUND="$(pull_matches "$TEST" | head -1)"
	[ -n "$FOUND" ] && break
	sleep 5
done
[ -n "$FOUND" ] && ok "feed delivered the change: $(jq -r '"\(.asset.name) updated \(.asset.updateTime // .window.startTime)"' <<<"$FOUND")" ||
	bad "no feed message for the binding within ${POLL_SECONDS}s"

section "Export it to BigQuery"
gcloud scheduler jobs run "${JOB##*/}" --location=us-central1 --project="$LOGGING" "$IMP" >/dev/null 2>&1 &&
	ok "triggered ${JOB##*/}" || bad "could not trigger ${JOB##*/}"
QUERY="SELECT COUNT(*) FROM \`${LOGGING}.asset_inventory.iam_policy\`, UNNEST(iam_policy.bindings) b, UNNEST(b.members) m WHERE b.role = '${ROLE}' AND LOWER(m) = '${OPERATOR_LC}' AND name LIKE '%/projects/${LOGGING_NUM}'"
ROWS=0
deadline=$((SECONDS + POLL_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
	ROWS="$(CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="$SA" bq --project_id="$LOGGING" query --use_legacy_sql=false --format=csv "$QUERY" 2>/dev/null | tail -1)"
	[[ "${ROWS:-}" =~ ^[0-9]+$ ]] && [ "$ROWS" -gt 0 ] && break
	sleep 15
done
[[ "${ROWS:-}" =~ ^[0-9]+$ ]] && [ "$ROWS" -gt 0 ] && ok "export holds the binding ($ROWS row)" || bad "binding not in asset_inventory.iam_policy within ${POLL_SECONDS}s"

section "Revert, find the removal in the feed"
revert && ok "removed the test binding (verified absent from the policy)" || bad "test binding still on $LOGGING after the revert; remove it by hand"
GONE="(.asset.name | endswith(\"/projects/${LOGGING_NUM}\")) and ([.asset.iamPolicy.bindings[]? | select(.role == \"${ROLE}\") | .members[]? | ascii_downcase] | index(\"${OPERATOR_LC}\") == null)"
FOUND=""
deadline=$((SECONDS + POLL_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
	FOUND="$(pull_matches "$GONE" | head -1)"
	[ -n "$FOUND" ] && break
	sleep 5
done
[ -n "$FOUND" ] && ok "feed delivered the removal" || bad "no feed message for the removal within ${POLL_SECONDS}s"

summary
