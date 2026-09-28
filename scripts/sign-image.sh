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

# Resolve the tag with a registry v2 manifest GET. Through the virtual repo that
# is a real pull: the remote repo fetches and caches the manifest on first use,
# which "gcloud artifacts docker images describe" never does (it only reads
# what is already cached). The index digest is what a node pulls by, so it is
# the one to attest.
HOST="${REF%%/*}"
NAME_TAG="${REF#*/}"
TOKEN="$(gcloud auth print-access-token "$IMP" 2>/dev/null)"
DIGEST="$(curl -sf -o /dev/null -D - \
	-H "Authorization: Bearer $TOKEN" \
	-H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
	"https://${HOST}/v2/${NAME_TAG%:*}/manifests/${NAME_TAG##*:}" |
	tr -d '\r' | awk -F': ' 'tolower($1) == "docker-content-digest" { print $2 }')"
if [ -z "$DIGEST" ]; then
	echo "could not resolve $REF through the registry" >&2
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
	if ! grep -Eq "ALREADY_EXISTS|is the subject of a conflict" <<<"$out"; then
		echo "$out" >&2
		exit 1
	fi
fi

echo "$DIGEST_REF"
