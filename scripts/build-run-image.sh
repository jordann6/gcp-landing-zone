#!/usr/bin/env bash
# Build a Cloud Run image from <root>/app, push it to the workload's CMEK apps
# repository (immutable tags), and pin it by digest in <root>/image.auto.tfvars.
#
# Usage: scripts/build-run-image.sh <root> <image-name>
#   scripts/build-run-image.sh rotation secret-rotator
#   scripts/build-run-image.sh slo orders-api
#
# Needs docker and the workload root applied, and <root> applied once (its
# repository output). Pushes as sa-terraform through impersonation; the
# operator holds no write on the prod app project.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

R="${1:?usage: build-run-image.sh <root> <image-name>}"
NAME="${2:?usage: build-run-image.sh <root> <image-name>}"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }

REPO="$(tfout "$R" repository)"
[ -n "$REPO" ] || { echo "$R/ has no repository output; run make deploy-$R first" >&2; exit 1; }

HOST="${REPO%%/*}"
gcloud auth print-access-token "$IMP" | docker login -u oauth2accesstoken --password-stdin "https://${HOST}" >/dev/null || exit 1

META="$(mktemp)"
trap 'rm -f "$META"' EXIT
TAG="${REPO}/${NAME}:$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)-$(date -u +%Y%m%d%H%M%S)"

# Cloud Run runs linux/amd64; this Mac may not.
docker buildx build --platform linux/amd64 --push --metadata-file "$META" -t "$TAG" "$ROOT/$R/app" || exit 1

DIGEST="$(jq -r '."containerimage.digest"' "$META")"
[ -n "$DIGEST" ] && [ "$DIGEST" != "null" ] || { echo "no digest in build metadata" >&2; exit 1; }

printf 'image = "%s/%s@%s"\n' "$REPO" "$NAME" "$DIGEST" >"$ROOT/$R/image.auto.tfvars"
echo "pinned $REPO/$NAME@$DIGEST in $R/image.auto.tfvars"
echo "next: make deploy-$R"
