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

# The password goes in the request body on stdin, not argv.
OP="$(printf '{"name":"app","password":"%s"}' "$PW" | curl -s -X PUT \
	-H "Authorization: Bearer $TOKEN" -H "x-goog-user-project: $SEED" -H "Content-Type: application/json" \
	"https://sqladmin.googleapis.com/sql/v1beta4/projects/$PROJECT/instances/$INSTANCE/users?name=app" -d @- | jq -r '.name // empty')"
[ -n "$OP" ] || { echo "Cloud SQL rejected the password update" >&2; exit 1; }
gcloud sql operations wait "$OP" --project="$PROJECT" --timeout=300 "$IMP" >/dev/null 2>&1 || { echo "password operation $OP did not finish" >&2; exit 1; }
echo "Cloud SQL user app: password set"

if printf '%s' "$PW" | gcloud secrets versions add "$SECRET" --project="$PROJECT" --data-file=- "$IMP" >/dev/null 2>&1; then
	echo "Secret Manager $SECRET: new version added"
else
	echo "password was set in Cloud SQL but the secret version add FAILED; re-run to set both again" >&2
	exit 1
fi
