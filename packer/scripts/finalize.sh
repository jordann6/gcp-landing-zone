#!/usr/bin/env bash
# Leave the image clean for its first boot. The mirror sources stay: they are
# how every VM booted from this image patches.
set -euo pipefail
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -f /etc/apt/sources.list.gce-original
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
find /var/log -type f -exec truncate -s 0 {} +
export HISTSIZE=0
sync
