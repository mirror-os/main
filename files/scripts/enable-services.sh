#!/bin/bash
set -euo pipefail

chmod +x /usr/bin/mirror-dev-reset

firewall-offline-cmd --add-service=localsend

# Trust the waydroid0 bridge in firewalld so that nftables NAT rules applied
# by waydroid are not blocked.  The interface is created dynamically by the
# container service, but registering it here ensures firewalld assigns it the
# correct zone as soon as it appears.
firewall-offline-cmd --zone=trusted --add-interface=waydroid0