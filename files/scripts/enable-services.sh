#!/bin/bash
set -euo pipefail

chmod +x /usr/bin/mirror-dev-reset

firewall-offline-cmd --add-service=localsend