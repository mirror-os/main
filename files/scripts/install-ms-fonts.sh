#!/usr/bin/env bash
# Mirror OS build-time script: installs Microsoft TrueType core fonts
set -euo pipefail

rpm -i --nodeps \
    https://downloads.sourceforge.net/project/mscorefonts2/rpms/msttcore-fonts-installer-2.6-1.noarch.rpm

exit 0
