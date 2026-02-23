#!/bin/bash
set -euo pipefail

# Make the first-boot scripts executable and enable their systemd services.
chmod +x /usr/libexec/mirror-os/install-nix.sh
chmod +x /usr/libexec/mirror-os/mirror-nix-setup.sh

systemctl enable install-nix.service
systemctl enable mirror-nix-setup.service
