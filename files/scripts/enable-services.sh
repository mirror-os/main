#!/bin/bash
set -euo pipefail

# Make the first-boot scripts executable and enable their systemd services.
chmod +x /usr/libexec/mirror-os/install-nix.sh
chmod +x /usr/libexec/mirror-os/mirror-nix-setup.sh
chmod +x /usr/bin/mirror-dev-reset

systemctl enable install-nix.service
systemctl enable mirror-nix-setup.service

firewall-offline-cmd --add-service=localsend

systemctl enable --global mirror-user-setup.service