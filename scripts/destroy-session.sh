#!/usr/bin/env bash
# Preserve failures and always verify, including when a backend is unavailable.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failed=0
if [[ $# -eq 0 ]]; then set -- observability incident compute workload network image terraform; fi
for root in "$@"; do
  if ! terraform -chdir="$ROOT/$root" init -input=false -backend-config=backend.hcl; then
    failed=1
    continue
  fi
  if terraform -chdir="$ROOT/$root" plan -destroy -input=false -out=tfplan; then
    terraform -chdir="$ROOT/$root" apply -input=false tfplan || failed=1
  else
    failed=1
  fi
done
"$ROOT/scripts/verify-teardown.sh" || failed=1
exit "$failed"
