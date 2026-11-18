#!/usr/bin/env bash
# Build the secret rotator image, push it to the workload's apps repository
# (CMEK, immutable tags), and pin it by digest in rotation/image.auto.tfvars.
#
# Needs docker and the workload root applied. Pushes as sa-terraform through
# impersonation; the operator holds no write on the prod app project.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

REPO="$(tfout rotation repository)"
[ -n "$REPO" ] || { echo "rotation/ has no repository output; run make deploy-rotation first" >&2; exit 1; }

HOST="${REPO%%/*}"
gcloud auth print-access-token "$IMP" | docker login -u oauth2accesstoken --password-stdin "https://${HOST}" >/dev/null || exit 1

META="$(mktemp)"
trap 'rm -f "$META"' EXIT
TAG="${REPO}/secret-rotator:$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)-$(date -u +%Y%m%d%H%M%S)"

# Cloud Run runs linux/amd64; this Mac may not.
docker buildx build --platform linux/amd64 --push --metadata-file "$META" -t "$TAG" "$ROOT/rotation/app" || exit 1

DIGEST="$(jq -r '."containerimage.digest"' "$META")"
[ -n "$DIGEST" ] && [ "$DIGEST" != "null" ] || { echo "no digest in build metadata" >&2; exit 1; }

printf 'image = "%s/secret-rotator@%s"\n' "$REPO" "$DIGEST" >"$ROOT/rotation/image.auto.tfvars"
echo "pinned $REPO/secret-rotator@$DIGEST in rotation/image.auto.tfvars"
echo "next: make deploy-rotation"
