#!/bin/bash
set -euo pipefail

chmod +x /usr/bin/mirror-dev-reset
chmod +x /usr/bin/mirror-dev-deploy
chmod +x /usr/bin/mirror-os
chmod +x /usr/bin/mirror-update
chmod +x /usr/libexec/mirror-os/mirror-nix-install
chmod +x /usr/libexec/mirror-os/mirror-flatpak-install
chmod +x /usr/libexec/mirror-os/mirror-init
chmod +x /usr/libexec/mirror-os/mirror-sync
chmod +x /usr/libexec/mirror-os/mirror-os
chmod +x /usr/libexec/mirror-os/mirror-catalog-update
chmod +x /usr/libexec/mirror-os/waydroid-prestart.sh

# sudoers files must be 0440 (root-readable only) or sudo will refuse them
chmod 0440 /etc/sudoers.d/mirror-os-chsh
chmod 0440 /etc/sudoers.d/mirror-os-nix-install

# Enable bootc automatic background update timer.
# Shipped by the bootc RPM; stages new images periodically but never forces a reboot.
systemctl enable bootc-fetch-apply-updates.timer

systemctl --global enable mirror-os-init.service
systemctl --global enable mirror-os-sync.timer
systemctl --global enable mirror-os-apps.path
systemctl --global enable mirror-os-catalog.timer

firewall-offline-cmd --add-service=localsend
# waydroid0 interface trust is declared statically via
# /etc/firewalld/zones/trusted.xml — no runtime command needed here.

# Strip broken nft/ip6tables-legacy command detection from waydroid's network
# script (mirrors the fix applied by Bazzite). Without this, the script fails
# to set up the waydroid0 bridge on Fedora Atomic because it looks for these
# commands in paths that don't exist inside the container build environment.
sed -i -E 's/=.\$\(command -v (nft|ip6tables-legacy).*/=/g' \
    /usr/lib/waydroid/data/scripts/waydroid-net.sh
