#!/usr/bin/env bash
# ExecStartPre script for waydroid-container.service.
# Patches the waydroid base props file with GBM/Mesa GPU settings so that
# hardware acceleration is never lost to a software fallback after a reboot.
# Runs as root; exits 0 silently if waydroid has not been initialised yet.

set -eo pipefail

PROPS="/var/lib/waydroid/waydroid_base.prop"

# Nothing to do until waydroid init has been run
[ -f "$PROPS" ] || exit 0

# Remove any existing gralloc/egl lines, then append the GBM/Mesa values.
# Using delete-then-append avoids sed in-place edge cases and guarantees
# the desired values are always present regardless of prior state.
sed -i '/^ro\.hardware\.gralloc=/d' "$PROPS"
sed -i '/^ro\.hardware\.egl=/d'     "$PROPS"

printf 'ro.hardware.gralloc=gbm\n' >> "$PROPS"
printf 'ro.hardware.egl=mesa\n'    >> "$PROPS"
