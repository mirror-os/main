#!/usr/bin/env bash
set -oue pipefail

# Ensure scripts are executable
chmod +x /usr/libexec/mirror-os/mirror-init
chmod +x /usr/libexec/mirror-os/mirror-sync

# Enable systemd user units at the system level so they apply to all users
mkdir -p /usr/lib/systemd/user/default.target.wants
mkdir -p /usr/lib/systemd/user/timers.target.wants

ln -sf /etc/systemd/user/mirror-os-init.service \
    /usr/lib/systemd/user/default.target.wants/mirror-os-init.service

ln -sf /etc/systemd/user/mirror-os-sync.service \
    /usr/lib/systemd/user/default.target.wants/mirror-os-sync.service

ln -sf /etc/systemd/user/mirror-os-sync.timer \
    /usr/lib/systemd/user/timers.target.wants/mirror-os-sync.timer

ln -sf /etc/systemd/user/mirror-os-apps.path \
    /usr/lib/systemd/user/default.target.wants/mirror-os-apps.path

echo "Mirror OS systemd user units enabled"
