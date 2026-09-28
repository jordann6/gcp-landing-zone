#!/usr/bin/env bash
# Resolve an image reference to its digest and attest it with the paved-road
# attestor. Binary Authorization admits by digest, never by tag: a tag can be
# moved to different bytes after it was approved, a digest cannot.
#
# Usage: scripts/sign-image.sh <registry>/<image>:<tag>
# Prints the digest reference to deploy.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

REF="${1:?usage: sign-image.sh <image:tag>}"
PROJECT="$(tfout workload project_id)"
ATTESTOR="$(tfjson workload attestor | jq -r .attestor)"
KEYVER="$(tfjson workload attestor | jq -r .key_version)"

# Pulling through the remote repo caches the image, which is what gives it a
# digest in our registry to sign.
DIGEST="$(gcloud artifacts docker images describe "$REF" "$IMP" --format='value(image_summary.digest)' 2>/dev/null)"
if [ -z "$DIGEST" ]; then
	echo "could not resolve $REF (is the image cached? a first pull goes through the remote repo)" >&2
	exit 1
fi
DIGEST_REF="${REF%:*}@${DIGEST}"

if ! out="$(gcloud beta container binauthz attestations sign-and-create \
	--project="$PROJECT" \
	--artifact-url="$DIGEST_REF" \
	--attestor="$ATTESTOR" \
	--attestor-project="$PROJECT" \
	--keyversion="${KEYVER#//cloudkms.googleapis.com/v1/}" \
	"$IMP" 2>&1)"; then
	# Re-signing an already attested digest is not an error for this script.
	if ! grep -q "ALREADY_EXISTS" <<<"$out"; then
		echo "$out" >&2
		exit 1
	fi
fi

echo "$DIGEST_REF"
