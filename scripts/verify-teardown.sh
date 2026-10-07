#!/usr/bin/env bash
# Post-destroy verification: fail if anything that bills by the hour survived.
#
# Checks two sources, because each misses something the other catches:
#   Terraform state    what the roots still think they own
#   the live org       what actually exists, including things Terraform never
#                      owned (a LoadBalancer Service's forwarding rule, a PVC's
#                      disk) that keep billing after every root is empty
#
# Deliberately NOT flagged (the allowed standing footprint, ~$0.50/mo or less):
# KMS key rings (cannot be deleted), key versions pending destruction, projects
# in DELETE_REQUESTED (billing unlinked, no charge).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

section "Terraform state"
for root in observability incident compute workload network image terraform; do
	if state="$(terraform -chdir="$ROOT/$root" state list 2>&1)"; then
		N="$(printf '%s\n' "$state" | sed '/^$/d' | wc -l | tr -d ' ')"
		[ "$N" = "0" ] && ok "$root/ state is empty" || bad "$root/ still tracks $N resources" "$state"
	else
		bad "$root/ state inventory unavailable" "$state"
	fi
done

section "Live org: hourly resources in any landing zone project"
if ! PROJECTS="$(gcloud projects list --filter='labels.project=gcp-landing-zone AND lifecycleState=ACTIVE' --format='value(projectId)' 2>/dev/null)"; then
	bad "live project inventory unavailable"
	summary
	exit 1
fi
if [ -z "$PROJECTS" ]; then
	ok "no ACTIVE landing zone projects remain (deleted projects linger 30 days in DELETE_REQUESTED at no cost)"
fi

for p in $PROJECTS; do
	found=""
	check() {
		local what="$1"
		shift
		local n
		if names="$("$@" --project="$p" --format='value(name)' 2>/dev/null)"; then
			n="$(printf '%s\n' "$names" | sed '/^$/d' | wc -l | tr -d ' ')"
		else
			bad "$p $what inventory unavailable"
			return
		fi
		[ "${n:-0}" != "0" ] && found="$found $what=$n"
	}
	check instances gcloud compute instances list
	check routers gcloud compute routers list
	check forwarding-rules gcloud compute forwarding-rules list
	check vpn-tunnels gcloud compute vpn-tunnels list
	check disks gcloud compute disks list
	check images gcloud compute images list --no-standard-images
	check snapshots gcloud compute snapshots list
	check addresses gcloud compute addresses list --filter='addressType=EXTERNAL'
	check clusters gcloud container clusters list
	# Not every project enables Artifact Registry, and listing against a
	# disabled API errors rather than returning nothing.
	if gcloud services list --enabled --project="$p" --filter='config.name=artifactregistry.googleapis.com' \
		--format='value(config.name)' 2>/dev/null | grep -q .; then
		check repositories gcloud artifacts repositories list
	fi
	check sql gcloud sql instances list
	# Backup and DR vaults enforce retention, so one holding backups survives a
	# destroy until they age out, and still bills. Listed as sa-terraform because
	# the operator has no backupdr permissions.
	if gcloud services list --enabled --project="$p" --filter='config.name=backupdr.googleapis.com' \
		--format='value(config.name)' 2>/dev/null | grep -q .; then
		# The seed project is bootstrap's, outside sa-terraform's grants, so it is
		# listed as the operator.
		vault_imp="$IMP"
		[ "$(gcloud projects describe "$p" --format='value(labels.layer)' 2>/dev/null)" = "seed" ] && vault_imp=""
		# shellcheck disable=SC2086
		check backup-vaults gcloud backup-dr backup-vaults list --location=- $vault_imp
	fi
	[ -z "$found" ] && ok "$p clean" || bad "$p still has:$found"
done

section "Org-level"
ORG="$(gcloud organizations list --format='value(name)' 2>/dev/null | head -1)"
for c in iam.disableServiceAccountKeyCreation iam.disableServiceAccountKeyUpload storage.uniformBucketLevelAccess; do
	if gcloud org-policies describe "$c" --organization="$ORG" --format=json >/dev/null 2>&1; then
		ok "Google default $c still present (destroy did not take it)"
	else
		bad "Google default $c is GONE. Restore: gcloud resource-manager org-policies enable-enforce $c --organization=$ORG"
	fi
done

summary
