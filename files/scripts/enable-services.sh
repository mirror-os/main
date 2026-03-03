#!/bin/bash
set -euo pipefail

chmod +x /usr/bin/mirror-dev-reset
chmod +x /usr/libexec/mirror-os/mirror-nix-install
chmod +x /usr/libexec/mirror-os/mirror-flatpak-install

# sudoers files must be 0440 (root-readable only) or sudo will refuse them
chmod 0440 /etc/sudoers.d/mirror-os-chsh
chmod 0440 /etc/sudoers.d/mirror-os-nix-install

firewall-offline-cmd --add-service=localsend
# waydroid0 interface trust is declared statically via
# /etc/firewalld/zones/trusted.xml — no runtime command needed here.

# Strip broken nft/ip6tables-legacy command detection from waydroid's network
# script (mirrors the fix applied by Bazzite). Without this, the script fails
# to set up the waydroid0 bridge on Fedora Atomic because it looks for these
# commands in paths that don't exist inside the container build environment.
sed -i -E 's/=.\$\(command -v (nft|ip6tables-legacy).*/=/g' \
    /usr/lib/waydroid/data/scripts/waydroid-net.sh
