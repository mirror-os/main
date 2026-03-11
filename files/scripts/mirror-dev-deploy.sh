#!/usr/bin/env bash
set -euo pipefail

# Mirror OS Development Deploy Script
# Copies OS files from the dev repo to the running system for quick iteration.
# Requires an rpm-ostree usroverlay to make /usr writable.
#
# Usage: mirror-dev-deploy [--repo <path>]
#   --repo <path>   Path to the MirrorOS main/ repo (default: auto-detect from script location)

# ── Locate repo root ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO_ROOT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: mirror-dev-deploy [--repo <path>]"
            echo ""
            echo "Copies files/ from the dev repo to the running system."
            echo "Requires: sudo rpm-ostree usroverlay  (run once per boot)"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

FILES_DIR="$REPO_ROOT/files"

if [ ! -d "$FILES_DIR" ]; then
    echo "ERROR: files/ directory not found at $FILES_DIR"
    echo "       Pass --repo <path-to-main/> if running from outside the repo."
    exit 1
fi

# ── Check /usr is writable ────────────────────────────────────────────────────
if ! touch /usr/.mirror-dev-deploy-check 2>/dev/null; then
    echo "ERROR: /usr/ is read-only."
    echo ""
    echo "Run the following to make /usr writable for this boot session:"
    echo "  sudo rpm-ostree usroverlay"
    echo ""
    echo "Then re-run mirror-dev-deploy."
    exit 1
fi
rm -f /usr/.mirror-dev-deploy-check

# ── Sync files ────────────────────────────────────────────────────────────────
echo "Deploying files from $FILES_DIR ..."

if [ -d "$FILES_DIR/usr" ]; then
    echo "  → /usr/ ..."
    sudo rsync -rlpt --delete "$FILES_DIR/usr/" /usr/
fi

if [ -d "$FILES_DIR/etc" ]; then
    echo "  → /etc/ ..."
    sudo rsync -rlpt "$FILES_DIR/etc/" /etc/
fi

# ── Restore execute permissions ───────────────────────────────────────────────
# BlueBuild strips execute bits; rsync preserves whatever the repo has.
# Explicitly set the bits that enable-services.sh manages at image build time.
echo "  → Restoring execute permissions..."

sudo chmod +x \
    /usr/bin/mirror-os \
    /usr/bin/mirror-update \
    /usr/bin/mirror-dev-reset \
    /usr/bin/mirror-dev-deploy \
    /usr/libexec/mirror-os/mirror-os \
    /usr/libexec/mirror-os/mirror-init \
    /usr/libexec/mirror-os/mirror-sync \
    /usr/libexec/mirror-os/mirror-nix-install \
    /usr/libexec/mirror-os/mirror-flatpak-install \
    /usr/libexec/mirror-os/mirror-catalog-update \
    /usr/libexec/mirror-os/waydroid-prestart.sh

# sudoers files must be 0440 or sudo will refuse them
if [ -f /etc/sudoers.d/mirror-os-chsh ];       then sudo chmod 0440 /etc/sudoers.d/mirror-os-chsh; fi
if [ -f /etc/sudoers.d/mirror-os-nix-install ]; then sudo chmod 0440 /etc/sudoers.d/mirror-os-nix-install; fi

echo ""
echo "Deploy complete. Changes are live until next reboot."
echo "Run 'sudo rpm-ostree usroverlay' again after rebooting to re-enable writes."
