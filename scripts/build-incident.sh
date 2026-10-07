#!/usr/bin/env bash
# Build the incident handler image, push it to the repository the incident root
# created, and pin it by digest in incident/image.auto.tfvars.
#
# Needs docker and the incident root applied once (the repository). Pushes as
# sa-terraform through impersonation: the operator holds no write on the
# logging project, by design.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

REPO="$(tfout incident repository)"
[ -n "$REPO" ] || { echo "incident/ has no repository output; run make deploy-incident first" >&2; exit 1; }

HOST="${REPO%%/*}"
gcloud auth print-access-token "$IMP" | docker login -u oauth2accesstoken --password-stdin "https://${HOST}" >/dev/null || exit 1

META="$(mktemp)"
trap 'rm -f "$META"' EXIT
TAG="${REPO}/handler:$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)-$(date -u +%Y%m%d%H%M%S)"

# Cloud Run runs linux/amd64; this Mac may not.
docker buildx build --platform linux/amd64 --push --metadata-file "$META" -t "$TAG" "$ROOT/incident/app" || exit 1

DIGEST="$(jq -r '."containerimage.digest"' "$META")"
[ -n "$DIGEST" ] && [ "$DIGEST" != "null" ] || { echo "no digest in build metadata" >&2; exit 1; }

printf 'image = "%s/handler@%s"\n' "$REPO" "$DIGEST" >"$ROOT/incident/image.auto.tfvars"
echo "pinned $REPO/handler@$DIGEST in incident/image.auto.tfvars"
echo "next: make deploy-incident"
