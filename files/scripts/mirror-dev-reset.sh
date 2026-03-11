#!/usr/bin/env bash
set -euo pipefail

# Mirror OS Development Reset Script
# Resets the user environment selectively for testing workflows.
# Runs as the regular user (not root).

# ── Usage ─────────────────────────────────────────────────────────────────────
usage() {
    echo "Usage: mirror-dev-reset [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --apps      Remove all app modules from apps/, clear instances.db, and run HM switch"
    echo "  --data      Clear mirror-os databases only (instances.db + catalog.db); no HM changes"
    echo "  --nix       Wipe Nix user profile, GC the store, and re-scaffold HM config from templates"
    echo "  --hm        Reset Home Manager config and rebuild Nix environment (also clears instances.db)"
    echo "  --flatpaks  Remove all Flatpaks; restarts mirror-os-flatpak-init.service to reinstall default apps immediately"
    echo "  --cosmic    Reset COSMIC desktop settings"
    echo "  --init      Remove .init-complete (mirror-init re-runs on next boot)"
    echo "  --full      All of the above (virgin system)"
    echo "  --help      Show this message"
    echo ""
    echo "No arguments: equivalent to --hm --flatpaks --cosmic"
    echo ""
    echo "Typical full reset: mirror-dev-reset --nix --hm --flatpaks --cosmic --init"
    echo "App-only reset:     mirror-dev-reset --apps"
    echo "Database-only wipe: mirror-dev-reset --data"
}

# ── Parse arguments ───────────────────────────────────────────────────────────
DO_APPS=false
DO_DATA=false
DO_NIX=false
DO_HM=false
DO_FLATPAKS=false
DO_COSMIC=false
DO_INIT=false

if [ $# -eq 0 ]; then
    DO_HM=true
    DO_FLATPAKS=true
    DO_COSMIC=true
fi

for arg in "$@"; do
    case "$arg" in
        --apps)     DO_APPS=true ;;
        --data)     DO_DATA=true ;;
        --nix)      DO_NIX=true ;;
        --hm)       DO_HM=true ;;
        --flatpaks) DO_FLATPAKS=true ;;
        --cosmic)   DO_COSMIC=true ;;
        --init)     DO_INIT=true ;;
        --full)     DO_APPS=true; DO_DATA=true; DO_NIX=true; DO_HM=true; DO_FLATPAKS=true; DO_COSMIC=true; DO_INIT=true ;;
        --help|-h)  usage; exit 0 ;;
        *)          echo "Unknown argument: $arg"; usage; exit 1 ;;
    esac
done

# ── Warning + confirmation ────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "WARNING: Mirror OS Development Reset"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "The following will be reset:"
if $DO_APPS;     then echo "  - App modules (apps/*.nix removed, instances.db cleared, HM switch run)"; fi
if $DO_DATA;     then echo "  - mirror-os databases (instances.db + catalog.db cleared)"; fi
if $DO_NIX;      then echo "  - Nix user profile and store (garbage-collect all old packages) + HM config re-scaffolded from templates"; fi
if $DO_HM;       then echo "  - Home Manager config and generations (including instances.db)"; fi
if $DO_FLATPAKS; then echo "  - All Flatpaks (default apps reinstall on next boot via mirror-os-flatpak-init.service)"; fi
if $DO_COSMIC;   then echo "  - COSMIC desktop settings"; fi
if $DO_INIT;     then echo "  - Init marker (mirror-init will re-run on next boot)"; fi
echo ""
echo "Press Ctrl+C to cancel, or Enter to continue..."
read -r

# ── Common setup ──────────────────────────────────────────────────────────────
REAL_USER=$(id -un)
REAL_HOME="$HOME"
TEMPLATES_DIR="/usr/share/mirror-os"
HM_DEST="$REAL_HOME/.config/home-manager"
MIRROR_DATA="$REAL_HOME/.local/share/mirror-os"
INSTANCES_DB="$MIRROR_DATA/instances.db"
CATALOG_DB="$MIRROR_DATA/catalog.db"

NIX_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix.sh"
# shellcheck source=/dev/null
source "$NIX_PROFILE"
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# ── App modules reset ─────────────────────────────────────────────────────────
# Fast path: wipe only the per-app .nix modules and instances.db, then run
# home-manager switch so the environment reflects the cleared app set.
# Does NOT wipe the Nix profile or re-scaffold from templates.
if $DO_APPS && ! $DO_HM && ! $DO_NIX; then
    echo "→ Removing app modules from apps/..."
    rm -f "$HM_DEST/apps/"*.nix 2>/dev/null || true
    echo "  → App modules removed."

    echo "→ Clearing instances.db..."
    rm -f "$INSTANCES_DB"
    echo "  → instances.db cleared."

    echo "→ Running home-manager switch to apply..."
    cd "$HM_DEST"
    nix run nixpkgs#home-manager -- switch --flake ".#$REAL_USER" --impure || \
        echo "  → home-manager switch completed with warnings (check output above)."
fi

# ── Database-only reset ───────────────────────────────────────────────────────
# Clears catalog.db and instances.db without touching the Nix environment.
# Use after testing installs/uninstalls to start fresh without a full HM rebuild.
if $DO_DATA; then
    echo "→ Clearing mirror-os databases..."
    rm -f "$INSTANCES_DB"
    echo "  → instances.db cleared."
    rm -f "$CATALOG_DB"
    echo "  → catalog.db cleared (run 'mirror-os catalog update' to rebuild)."
fi

# ── Nix user profile reset ────────────────────────────────────────────────────
# Runs before --hm so the store is clean before home-manager switch rebuilds it.
if $DO_NIX; then
    echo "→ Wiping Nix user profile..."

    # Expire all home-manager generations so GC can collect their store paths.
    home-manager expire-generations "-0 days" 2>/dev/null || true

    # Remove all entries from the standalone Nix user profile (e.g. anything
    # installed directly via 'nix profile install' outside of home-manager).
    nix profile wipe-history 2>/dev/null || true

    # Collect garbage: this is the step that actually deletes store paths freed
    # by expire-generations and wipe-history.  Without it, old packages
    # (including stale Waydroid versions) remain on disk indefinitely.
    echo "  → Running garbage collection (may take a moment)..."
    nix-collect-garbage -d 2>/dev/null || true

    # Remove the profile symlink so home-manager switch starts with a blank
    # slate rather than layering on top of whatever was previously active.
    rm -f "$REAL_HOME/.nix-profile"

    echo "  → Nix user profile wiped."

    # Clear instances.db — all app records become stale when the HM config is wiped.
    echo "  → Clearing instances.db..."
    rm -f "$INSTANCES_DB"

    # Re-scaffold home-manager config from the current image templates so the
    # next switch picks up any template changes made during development.
    echo "  → Re-scaffolding home-manager config from templates..."
    rm -rf "$HM_DEST"
    mkdir -p "$HM_DEST/apps"

    # home.nix lives read-only in the image at /usr/share/mirror-os/home.nix
    # and is imported directly by flake.nix — it is NOT a user scaffold.
    for template in flake.nix home-user.nix; do
        sed "s/__USERNAME__/$REAL_USER/g" \
            "$TEMPLATES_DIR/${template}.template" \
            > "$HM_DEST/$template"
    done

    git -C "$HM_DEST" init -b main -q
    git -C "$HM_DEST" config user.email "$REAL_USER@mirror-os.local"
    git -C "$HM_DEST" config user.name "$REAL_USER"
    git -C "$HM_DEST" add .
    git -C "$HM_DEST" commit -m "initial" -q

    # Update the image hash so mirror-sync doesn't immediately redo the
    # image-update refresh on top of the freshly scaffolded config.
    _new_hash=$(sha256sum \
        /usr/share/mirror-os/home.nix \
        /usr/share/mirror-os/flake.nix.template \
        /usr/share/mirror-os/home-user.nix.template \
        2>/dev/null | sha256sum | cut -d' ' -f1 || true)
    [ -n "$_new_hash" ] && \
        echo "$_new_hash" > "$REAL_HOME/.local/share/mirror-os/state/system-hm.hash"

    echo "  → Home Manager config re-scaffolded. Run --hm or 'home-manager switch' to apply."
fi

# ── Home Manager reset ────────────────────────────────────────────────────────
if $DO_HM; then
    echo "→ Resetting Home Manager config..."
    echo "  Note: apps/ will be wiped — re-run 'mirror-os install' for each app afterwards."

    # Expire old HM generations before wiping the config dir; home-manager
    # reads generation metadata from the nix profile, not the config dir.
    echo "→ Expiring old Home Manager generations..."
    home-manager expire-generations "-0 days" 2>/dev/null || true

    # Clear instances.db — records are stale once apps/ is wiped.
    echo "→ Clearing instances.db..."
    rm -f "$INSTANCES_DB"

    rm -rf "$HM_DEST"
    mkdir -p "$HM_DEST/apps"

    # home.nix lives read-only in the image at /usr/share/mirror-os/home.nix
    # and is imported directly by flake.nix — it is NOT a user scaffold.
    for template in flake.nix home-user.nix; do
        sed "s/__USERNAME__/$REAL_USER/g" \
            "$TEMPLATES_DIR/${template}.template" \
            > "$HM_DEST/$template"
    done

    git -C "$HM_DEST" init -b main -q
    git -C "$HM_DEST" config user.email "$REAL_USER@mirror-os.local"
    git -C "$HM_DEST" config user.name "$REAL_USER"
    git -C "$HM_DEST" add .
    git -C "$HM_DEST" commit -m "initial" -q

    echo "→ Configuring user-scope Flatpak remote..."
    flatpak remote-add --user --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true

    echo "→ Rebuilding Home Manager environment..."
    # Remove the nix profile symlink so the switch starts from a clean slate
    # rather than layering on top of whatever was previously active (e.g. stale
    # cosmic-manager packages from an old generation).
    rm -f "$REAL_HOME/.nix-profile"

    cd "$HM_DEST"
    nix run nixpkgs#home-manager -- switch --flake ".#$REAL_USER" --impure || \
        echo "  → home-manager switch completed with warnings (check output above)."

    # Update the image hash so mirror-sync doesn't immediately redo the
    # image-update refresh on top of the freshly reset config.
    _new_hash=$(sha256sum \
        /usr/share/mirror-os/home.nix \
        /usr/share/mirror-os/flake.nix.template \
        /usr/share/mirror-os/home-user.nix.template \
        2>/dev/null | sha256sum | cut -d' ' -f1 || true)
    [ -n "$_new_hash" ] && \
        echo "$_new_hash" > "$REAL_HOME/.local/share/mirror-os/state/system-hm.hash"
fi

# ── Flatpak reset ─────────────────────────────────────────────────────────────
if $DO_FLATPAKS; then
    echo "→ Removing all Flatpak apps (system and user scope)..."
    sudo flatpak uninstall --system --all --noninteractive || true
    flatpak uninstall --user --all --noninteractive || true

    # Clear stale Flatpak state from the git state repo.
    rm -f "$REAL_HOME/.local/share/mirror-os/state/flatpak-apps.list"
    rm -f "$REAL_HOME/.local/share/mirror-os/state/flatpak-full.list"

    # mirror-os-flatpak-init.service is a reconciler with no stamp file — it
    # runs on every boot.  Restart it now to reinstall default apps immediately
    # without waiting for a reboot.
    echo "→ Reinstalling system Flatpak apps..."
    sudo systemctl restart mirror-os-flatpak-init.service || \
        echo "  → Service restart failed — default apps will reinstall on next boot."
fi

# ── COSMIC reset ──────────────────────────────────────────────────────────────
if $DO_COSMIC; then
    echo "→ Resetting COSMIC desktop settings..."
    rm -rf "$REAL_HOME/.config/cosmic"
    cp -r /usr/share/cosmic "$REAL_HOME/.config/cosmic"
    echo "  → COSMIC config reset to Mirror OS defaults."
fi

# ── Init marker removal ───────────────────────────────────────────────────────
if $DO_INIT; then
    echo "→ Removing init-complete marker..."
    rm -f "$REAL_HOME/.local/share/mirror-os/.init-complete"
    echo "  → mirror-init will run on next boot."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo "Reset complete. Please reboot for all changes to take effect."
