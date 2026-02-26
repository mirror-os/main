#!/bin/bash
set -euo pipefail

# Make the first-boot scripts executable and enable their systemd services.
chmod +x /usr/libexec/mirror-os/install-nix.sh
chmod +x /usr/libexec/mirror-os/mirror-nix-setup.sh
chmod +x /usr/bin/mirror-dev-reset

systemctl enable install-nix.service
systemctl enable mirror-nix-setup.service

firewall-offline-cmd --add-service=localsend

# enable the user service globally (applies to all current and future users).
bashsystemctl enable --global mirror-user-setup.service