#!/bin/bash
set -euo pipefail

chmod +x /usr/bin/mirror-dev-reset

# sudoers files must be 0440 (root-readable only) or sudo will refuse them
chmod 0440 /etc/sudoers.d/mirror-os-chsh

firewall-offline-cmd --add-service=localsend
# waydroid0 interface trust is declared statically via
# /etc/firewalld/zones/trusted.xml — no runtime command needed here.