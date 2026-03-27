#!/bin/bash
# build-catalog.sh — Build the initial app catalog database during image construction.
# Runs as a BlueBuild script module, after the files and default-flatpaks modules.
#
# Produces:
#   /usr/share/mirror-os/catalog.db       — SQLite catalog database
#   /usr/share/mirror-os/media/icons/     — 128x128 PNG icons for all Flathub apps
#
# On first user login, mirror-catalog-bootstrap copies these into the user's
# data directory so the Software Center is populated immediately.

set -uo pipefail

log() { echo "[build-catalog] $*"; }

# Skip if a pre-built catalog was injected into the image by the CI catalog job.
# The files module copies files/usr/ → /usr/ before this script runs, so a
# pre-built catalog.db and icons are already at /usr/share/mirror-os/ when CI
# injects them. Detect by checking that both Flatpak and Nix data are present.
if python3 - << 'PYEOF' 2>/dev/null; then
import sqlite3, sys
try:
    conn = sqlite3.connect('/usr/share/mirror-os/catalog.db')
    nix  = conn.execute('SELECT count(*) FROM nix_packages').fetchone()[0]
    flat = conn.execute('SELECT count(*) FROM flatpak_apps').fetchone()[0]
    conn.close()
    sys.exit(0 if nix > 0 and flat > 0 else 1)
except Exception:
    sys.exit(1)
PYEOF
    FLAT_COUNT=$(python3 -c "import sqlite3; c=sqlite3.connect('/usr/share/mirror-os/catalog.db'); print(c.execute('SELECT count(*) FROM flatpak_apps').fetchone()[0])")
    NIX_COUNT=$(python3 -c "import sqlite3; c=sqlite3.connect('/usr/share/mirror-os/catalog.db'); print(c.execute('SELECT count(*) FROM nix_packages').fetchone()[0])")
    log "Pre-built catalog detected (${FLAT_COUNT} Flatpak, ${NIX_COUNT} Nix) — skipping local build."
    exit 0
fi

log "Starting catalog build..."

# ── Download Flathub AppStream metadata and icon cache ──────────────────────
log "Downloading Flathub AppStream cache (XML + icons)..."
if ! flatpak update --appstream --system --noninteractive 2>&1; then
    log "WARNING: flatpak update --appstream failed — creating empty catalog placeholder."
    mkdir -p /usr/share/mirror-os/media/icons
    python3 -c "import sqlite3; sqlite3.connect('/usr/share/mirror-os/catalog.db').close()"
    exit 0
fi

# ── Run Phase 1 of mirror-catalog-update ────────────────────────────────────
# Phase 1 parses the AppStream XML and copies icons from the AppStream icon
# cache — no network calls beyond the flatpak update above.
log "Parsing AppStream XML and indexing Flatpak apps..."
BUILD_HOME=/tmp/catalog-build
mkdir -p "$BUILD_HOME/.local/share/mirror-os"

HOME="$BUILD_HOME" /usr/libexec/mirror-os/mirror-catalog-update \
    --build --source flatpak --no-media

# ── Sanitise icon paths before baking into image ────────────────────────────
# icon_local_path values point to $BUILD_HOME (a build-time temp path).
# Clear them here; mirror-catalog-bootstrap repopulates them on first login
# once icons are copied to the user's actual media directory.
log "Clearing build-time icon paths from catalog.db..."
python3 - "$BUILD_HOME/.local/share/mirror-os/catalog.db" << 'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1], timeout=30)
with conn:
    conn.execute("UPDATE flatpak_apps SET icon_local_path = ''")
conn.close()
PYEOF

# ── Install into image ───────────────────────────────────────────────────────
mkdir -p /usr/share/mirror-os/media
cp "$BUILD_HOME/.local/share/mirror-os/catalog.db" /usr/share/mirror-os/catalog.db
cp -r "$BUILD_HOME/.local/share/mirror-os/media/icons" /usr/share/mirror-os/media/icons

ICON_COUNT=$(ls /usr/share/mirror-os/media/icons/*.png 2>/dev/null | wc -l)
DB_SIZE=$(du -sh /usr/share/mirror-os/catalog.db | cut -f1)
log "Done: ${DB_SIZE} catalog.db, ${ICON_COUNT} icons."

rm -rf "$BUILD_HOME"
