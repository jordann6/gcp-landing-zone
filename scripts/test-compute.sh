#!/usr/bin/env bash
# Prove the compute baseline on live resources (needs make deploy-compute;
# the GKE section also needs make deploy-workload).
#
#   Image policy   trustedImageProjects admits the golden image project and
#                  the GKE node image projects, and rejects a stock image
#   Management VM  boots from the golden family, no external IP, shielded,
#                  OS Login + OS Config on
#   Guest          check-hardening.sh from the pinned role tag passes on the
#                  live VM over IAP
#   Package path   apt reads the Artifact Registry mirror; the Ubuntu archive
#                  itself is unreachable
#   Patching       an OS Config patch job runs to success on the VM
#   GKE            COS and Ubuntu node pools both boot under the allowlist

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

HARDENING_REPO="${HARDENING_REPO:-$ROOT/../azure-vm-hardening}"
ROLE_COMMIT="b5ce929ee940f4ac6a1975ef507db6799e6464f9"

VM="$(tfjson compute management_vm)"
if [ -z "$VM" ] || [ "$VM" = "null" ]; then
	echo "compute/ has no management_vm output; run make deploy-compute first" >&2
	exit 1
fi
V_NAME="$(jq -r .name <<<"$VM")"
V_ZONE="$(jq -r .zone <<<"$VM")"
V_PROJ="$(jq -r .project <<<"$VM")"
IMAGE_PROJECT="$(tfout image project_id)"
SUBNET="$(tfjson network vpcs | jq -r '[.[] | select(.restricted and .env == "prod")][0].subnet')"

ssh_vm() {
	gcloud compute ssh "$V_NAME" --zone="$V_ZONE" --project="$V_PROJ" --tunnel-through-iap \
		--quiet --command="$1" 2>/dev/null
}

section "Image policy"
EFF="$(gcloud org-policies describe compute.trustedImageProjects --effective --project="$V_PROJ" "$IMP" --format=json 2>/dev/null)"
ALLOWED="$(jq -r '.spec.rules[].values.allowedValues[]?' <<<"$EFF" 2>/dev/null | sort | tr '\n' ' ')"
grep -q "projects/$IMAGE_PROJECT" <<<"$ALLOWED" && ok "golden image project trusted in $V_PROJ" || bad "image project missing from the effective allowlist" "$ALLOWED"
for p in cos-cloud gke-node-images ubuntu-os-gke-cloud; do
	grep -q "projects/$p " <<<"$ALLOWED " && ok "GKE image project $p trusted" || bad "GKE image project $p missing" "$ALLOWED"
done
grep -q "projects/ubuntu-os-cloud" <<<"$ALLOWED" && bad "stock ubuntu-os-cloud is trusted outside the image project" || ok "stock ubuntu-os-cloud not trusted outside the image project"

OSC="$(gcloud org-policies describe compute.requireOsConfig --effective --project="$V_PROJ" "$IMP" --format='value(spec.rules[0].enforce)' 2>/dev/null)"
[ "$OSC" = "True" ] || [ "$OSC" = "true" ] && ok "compute.requireOsConfig enforced" || bad "compute.requireOsConfig not enforced ($OSC)"

# As sa-terraform, which could create this VM if the image were allowed, so the
# denial is the policy and not missing IAM.
DENY_VM="deny-stock-image-$$"
expect_denied "stock Debian image rejected by trustedImageProjects" "trustedImageProjects" \
	gcloud compute instances create "$DENY_VM" --project="$V_PROJ" --zone="$V_ZONE" \
	--machine-type=e2-micro --image-family=debian-12 --image-project=debian-cloud \
	--subnet="$SUBNET" --no-address --shielded-secure-boot --shielded-vtpm \
	--shielded-integrity-monitoring "$IMP" ||
	gcloud compute instances delete "$DENY_VM" --project="$V_PROJ" --zone="$V_ZONE" --quiet "$IMP" >/dev/null 2>&1

section "Management VM"
DESC="$(gcloud compute instances describe "$V_NAME" --zone="$V_ZONE" --project="$V_PROJ" --format=json)"
DISK="$(jq -r '.disks[] | select(.boot) | .source' <<<"$DESC")"
SRC="$(gcloud compute disks describe "${DISK##*/}" --zone="$V_ZONE" --project="$V_PROJ" --format='value(sourceImage)' 2>/dev/null)"
[[ "$SRC" == *"/projects/$IMAGE_PROJECT/global/images/hardened-ubuntu-2204-"* ]] && ok "boots from the golden family (${SRC##*/})" || bad "unexpected boot image" "$SRC"
[ "$(jq '[.networkInterfaces[].accessConfigs // [] | length] | add' <<<"$DESC")" = "0" ] && ok "no external IP" || bad "external IP attached"
[ "$(jq -r '.shieldedInstanceConfig.enableSecureBoot and .shieldedInstanceConfig.enableVtpm and .shieldedInstanceConfig.enableIntegrityMonitoring' <<<"$DESC")" = "true" ] &&
	ok "Secure Boot, vTPM, integrity monitoring" || bad "shielded VM settings incomplete"
for key in enable-oslogin enable-osconfig block-project-ssh-keys; do
	[ "$(jq -r --arg k "$key" '.metadata.items[] | select(.key == $k) | .value' <<<"$DESC")" = "TRUE" ] && ok "metadata $key=TRUE" || bad "metadata $key not TRUE"
done

section "Guest hardening (IAP + OS Login)"
if CHECK="$(git -C "$HARDENING_REPO" show "$ROLE_COMMIT:scripts/check-hardening.sh" 2>/dev/null)"; then
	OUT="$(gcloud compute ssh "$V_NAME" --zone="$V_ZONE" --project="$V_PROJ" --tunnel-through-iap --quiet \
		--command='sudo bash -s' <<<"$CHECK" 2>/dev/null || true)"
	while IFS= read -r line; do echo "        $line"; done <<<"$OUT"
	N="$(grep -c '^PASS:' <<<"$OUT")"
	if grep -qx HARDENING_OK <<<"$OUT" && ! grep -q '^FAIL:' <<<"$OUT"; then
		ok "pinned check-hardening.sh passes on the live VM ($N guest checks)"
	else
		bad "guest hardening proof failed or incomplete"
	fi
else
	bad "cannot read check-hardening.sh at $ROLE_COMMIT from $HARDENING_REPO"
fi

section "Package path"
ssh_vm 'sudo apt-get update -o Acquire::Retries=2 >/dev/null 2>&1 && apt-cache policy auditd | grep -q "ar+https"' &&
	ok "apt updates from the Artifact Registry mirror" || bad "apt cannot read the mirror"
CODE="$(ssh_vm 'curl -s -m 10 -o /dev/null -w "%{http_code}" http://archive.ubuntu.com/ubuntu/ || true')"
[[ -z "$CODE" || "$CODE" == "000" ]] && ok "Ubuntu archive unreachable directly (mirror is the only path)" || bad "archive.ubuntu.com reachable ($CODE)"

section "Patching (OS Config)"
JOB="$(gcloud compute os-config patch-jobs execute --project="$V_PROJ" \
	--instance-filter-names="zones/$V_ZONE/instances/$V_NAME" \
	--reboot-config=never --duration=1800s --display-name=test-compute --async \
	--format='value(name)' 2>/dev/null)"
JOB="${JOB##*$'\n'}"
if [[ "$JOB" == projects/* ]]; then
	STATE=""
	for _ in $(seq 1 60); do
		STATE="$(gcloud compute os-config patch-jobs describe "${JOB##*/}" --project="$V_PROJ" --format='value(state)' 2>/dev/null)"
		case "$STATE" in SUCCEEDED | COMPLETED_WITH_ERRORS | TIMED_OUT | CANCELED) break ;; esac
		sleep 20
	done
	[ "$STATE" = "SUCCEEDED" ] && ok "patch job ${JOB##*/} SUCCEEDED" || bad "patch job ended $STATE" "$(gcloud compute os-config patch-jobs list-instance-details "${JOB##*/}" --project="$V_PROJ" 2>&1)"
else
	bad "patch job did not start" "${JOB:-no job name returned}"
fi
DEP="$(gcloud compute os-config patch-deployments list --project="$V_PROJ" --format='value(name)' 2>/dev/null | grep -c mgmt-weekly)"
[ "$DEP" = "1" ] && ok "weekly patch deployment present" || bad "patch deployment mgmt-weekly missing"

section "GKE node images (needs make deploy-workload)"
CLUSTER="$(tfjson workload cluster 2>/dev/null)"
if [ -n "$CLUSTER" ] && [ "$CLUSTER" != "null" ]; then
	C_NAME="$(jq -r .name <<<"$CLUSTER")"
	C_LOC="$(jq -r .location <<<"$CLUSTER")"
	C_PROJ="$(tfout workload project_id)"
	POOLS="$(gcloud container node-pools list --cluster="$C_NAME" --location="$C_LOC" --project="$C_PROJ" "$IMP" --format=json 2>/dev/null)"
	for pool in $(jq -r '.[].name' <<<"$POOLS"); do
		P="$(jq -c --arg n "$pool" '.[] | select(.name == $n)' <<<"$POOLS")"
		STATUS="$(jq -r .status <<<"$P")"
		TYPE="$(jq -r .config.imageType <<<"$P")"
		NODES="$(gcloud compute instances list --project="$C_PROJ" "$IMP" \
			--filter="labels.goog-k8s-node-pool-name=$pool AND status=RUNNING" --format='value(name)' 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
		[ "$STATUS" = "RUNNING" ] && [ "${NODES:-0}" -ge 1 ] && ok "$pool ($TYPE) RUNNING with $NODES node(s) under the allowlist" ||
			bad "$pool ($TYPE) status $STATUS with ${NODES:-0} running node(s)"
	done
	jq -e '.[] | select(.config.imageType == "UBUNTU_CONTAINERD")' <<<"$POOLS" >/dev/null ||
		skip "no Ubuntu node pool (set enable_ubuntu_node_pool = true in workload/ to prove ubuntu-os-gke-cloud)"
else
	skip "GKE checks (workload root not deployed)"
fi

summary
