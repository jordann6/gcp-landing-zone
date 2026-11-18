#!/usr/bin/env bash
# Set the app database password out of band: Cloud SQL and the Secret Manager
# shell get the same fresh value in one step, and it never touches Terraform
# state, a file, or a command line. Re-run it to rotate by hand.
#
# Runs as sa-terraform (sqladmin and secretmanager are VPC-SC restricted; the
# operator is outside the perimeter by design).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

PROJECT="$(tfout workload project_id)"
INSTANCE="$(tfjson workload sql | jq -r .primary)"
SECRET="$(tfout workload db_secret | sed 's|.*/||')"
SEED="$(tfout bootstrap seed_project_id)"
[ -n "$PROJECT" ] && [ -n "$INSTANCE" ] && [ -n "$SECRET" ] || { echo "workload/ outputs missing; deploy workload first" >&2; exit 1; }

PW="$(openssl rand -hex 16)"
TOKEN="$(gcloud auth print-access-token "$IMP" 2>/dev/null)"

# The password goes in the request body on stdin, not argv. Create the user on
# first run (workload/ does not manage it); update it on every run after.
BASE="https://sqladmin.googleapis.com/sql/v1beta4/projects/$PROJECT/instances/$INSTANCE/users"
sql_user() { # $1 = method, $2 = url
	printf '{"name":"app","password":"%s"}' "$PW" | curl -s -X "$1" \
		-H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $SEED" -H "Content-Type: application/json" "$2" -d @-
}
RESP="$(sql_user POST "$BASE")"
OP="$(jq -r '.name // empty' <<<"$RESP")"
if [ -z "$OP" ] && grep -qiE "already exists|ALREADY_EXISTS|409" <<<"$RESP"; then
	OP="$(sql_user PUT "$BASE?name=app" | jq -r '.name // empty')"
fi
[ -n "$OP" ] || { echo "Cloud SQL rejected the user/password request: $(jq -r '.error.message // "unknown"' <<<"$RESP")" >&2; exit 1; }
gcloud sql operations wait "$OP" --project="$PROJECT" --timeout=300 "$IMP" >/dev/null 2>&1 || { echo "password operation $OP did not finish" >&2; exit 1; }
echo "Cloud SQL user app: password set"

if printf '%s' "$PW" | gcloud secrets versions add "$SECRET" --project="$PROJECT" --data-file=- "$IMP" >/dev/null 2>&1; then
	echo "Secret Manager $SECRET: new version added"
else
	echo "password was set in Cloud SQL but the secret version add FAILED; re-run to set both again" >&2
	exit 1
fi
