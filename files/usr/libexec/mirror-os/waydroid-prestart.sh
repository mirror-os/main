#!/usr/bin/env bash
# ExecStartPre drop-in script for waydroid-container.service.
# Patches waydroid_base.prop with the correct GPU and udev settings before
# every container start, so values are never lost after a reboot.
# Runs as root; exits 0 silently if waydroid has not been initialised yet.

set -eo pipefail

PROPS="/var/lib/waydroid/waydroid_base.prop"

# Nothing to do until waydroid init has been run
[ -f "$PROPS" ] || exit 0

# GPU: minigbm_gbm_mesa gralloc and Mesa EGL backend (matches Bazzite/upstream)
sed -i '/^ro\.hardware\.gralloc=/d' "$PROPS"
sed -i '/^ro\.hardware\.egl=/d'     "$PROPS"
printf 'ro.hardware.gralloc=minigbm_gbm_mesa\n' >> "$PROPS"
printf 'ro.hardware.egl=mesa\n'                 >> "$PROPS"

# udev/uevent: required for input devices and hotplug to work inside the container
grep -qxF 'persist.waydroid.udev=true'   "$PROPS" || printf 'persist.waydroid.udev=true\n'   >> "$PROPS"
grep -qxF 'persist.waydroid.uevent=true' "$PROPS" || printf 'persist.waydroid.uevent=true\n' >> "$PROPS"
