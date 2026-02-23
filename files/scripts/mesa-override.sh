#!/bin/bash
set -euo pipefail

# Replace mesa-va-drivers with the RPM Fusion freeworld variant to unlock
# H.264/HEVC hardware decoding on Intel and AMD GPUs via VA-API.
#
# --arch=x86_64 prevents dnf from downloading the i686 variant, which has
# an unresolvable spirv-tools-libs dependency in the container build context.
dnf download \
    --arch=x86_64 \
    --repo=rpmfusion-free \
    --repo=rpmfusion-free-updates \
    --destdir=/tmp/mesa-overrides \
    mesa-va-drivers

rpm-ostree override replace /tmp/mesa-overrides/*.rpm

rm -rf /tmp/mesa-overrides
