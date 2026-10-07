#!/usr/bin/env bash
# Switch apt from the public Ubuntu archive to the Artifact Registry mirror.
# Runs as root on the bake VM, which has no route to the internet.
set -euo pipefail

: "${APT_SOURCES_B64:?APT_SOURCES_B64 must carry the base64 ar+https sources lines}"
APT_SOURCES="$(printf '%s' "$APT_SOURCES_B64" | base64 -d)"

# cloud-init's apt_configure rewrites /etc/apt/sources.list on first boot, and
# with no internet route it gets there about a minute in, which can be after
# this script has started. Wait it out, then tell it to leave the sources alone
# on every instance booted from this image, or the management VM would lose
# the mirror on its first boot and OS Config patching would fail.
cloud-init status --wait >/dev/null || true
cat >/etc/cloud/cloud.cfg.d/99-landing-zone-apt.cfg <<'CFG'
# Landing zone golden image: apt reads the Artifact Registry mirror.
apt:
  preserve_sources_list: true
CFG

dpkg -i /tmp/apt-transport-artifact-registry.deb
rm -f /tmp/apt-transport-artifact-registry.deb

# The GCE image ships sources pointing at *.gce.archive.ubuntu.com. Keep a copy
# for the record, then replace them; the deb822 file is emptied, not deleted,
# so a package upgrade does not quietly restore it.
cp /etc/apt/sources.list /etc/apt/sources.list.gce-original
printf '%s\n' "$APT_SOURCES" >/etc/apt/sources.list
if [ -d /etc/apt/sources.list.d ]; then
	find /etc/apt/sources.list.d -name '*.list' -o -name '*.sources' | while read -r f; do
		: >"$f"
	done
fi

apt-get update -o Acquire::Retries=3
# Captured, not piped into grep -q: under pipefail, grep exiting on the first
# match SIGPIPEs apt-cache and fails a check that actually passed.
policy="$(apt-cache policy auditd fail2ban)"
if ! grep -q 'ar+https' <<<"$policy" || grep -q 'Candidate: (none)' <<<"$policy"; then
	echo "mirror did not serve auditd/fail2ban indexes" >&2
	{
		echo "--- apt-cache policy auditd fail2ban"
		echo "$policy"
		echo "--- apt-cache policy (sources)"
		apt-cache policy | head -40
		echo "--- /var/lib/apt/lists"
		find /var/lib/apt/lists -maxdepth 1 -type f -printf "%s %f\n" | head -60
		echo "--- apt-cache show auditd"
		apt-cache show auditd 2>&1 | head -5
		echo "--- apt-cache stats"
		apt-cache stats 2>&1 | head -5
	} >&2
	exit 1
fi
echo "MIRROR_OK"
