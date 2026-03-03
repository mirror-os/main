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
    echo "  --nix       Wipe Nix user profile and garbage-collect the store"
    echo "  --hm        Reset Home Manager config and rebuild Nix environment"
    echo "  --flatpaks  Remove all Flatpaks; default apps reinstall on next boot via mirror-os-flatpak-init.service"
    echo "  --cosmic    Reset COSMIC desktop settings"
    echo "  --init      Remove .init-complete (mirror-init re-runs on next boot)"
    echo "  --full      All of the above (virgin system)"
    echo "  --help      Show this message"
    echo ""
    echo "No arguments: equivalent to --hm --flatpaks --cosmic"
    echo ""
    echo "Typical full reset: mirror-dev-reset --nix --hm --flatpaks --cosmic --init"
}

# ── Parse arguments ───────────────────────────────────────────────────────────
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
        --nix)      DO_NIX=true ;;
        --hm)       DO_HM=true ;;
        --flatpaks) DO_FLATPAKS=true ;;
        --cosmic)   DO_COSMIC=true ;;
        --init)     DO_INIT=true ;;
        --full)     DO_NIX=true; DO_HM=true; DO_FLATPAKS=true; DO_COSMIC=true; DO_INIT=true ;;
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
if $DO_NIX;      then echo "  - Nix user profile and store (garbage-collect all old packages)"; fi
if $DO_HM;       then echo "  - Home Manager config and generations"; fi
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

NIX_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix.sh"
# shellcheck source=/dev/null
source "$NIX_PROFILE"
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

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
fi

# ── Home Manager reset ────────────────────────────────────────────────────────
if $DO_HM; then
    echo "→ Resetting Home Manager config..."
    rm -rf "$HM_DEST"
    mkdir -p "$HM_DEST"

    for template in flake.nix home.nix home-mirror-cosmic.nix home-user.nix; do
        sed "s/__USERNAME__/$REAL_USER/g" \
            "$TEMPLATES_DIR/${template}.template" \
            > "$HM_DEST/$template"
    done

    git -C "$HM_DEST" init -b main
    git -C "$HM_DEST" config user.email "$REAL_USER@mirror-os.local"
    git -C "$HM_DEST" config user.name "$REAL_USER"
    git -C "$HM_DEST" add .
    git -C "$HM_DEST" commit -m "initial"

    echo "→ Expiring old Home Manager generations..."
    home-manager expire-generations "-0 days" || true

    echo "→ Rebuilding Home Manager environment..."
    nix profile remove home-manager 2>/dev/null && \
        echo "  → Removed standalone home-manager from nix profile" || true

    cd "$HM_DEST"
    nix run nixpkgs#home-manager -- switch --flake ".#$REAL_USER" || \
        echo "  → home-manager switch completed with warnings (check output above)."
fi

# ── Flatpak reset ─────────────────────────────────────────────────────────────
if $DO_FLATPAKS; then
    echo "→ Removing all Flatpak apps (system and user scope)..."
    sudo flatpak uninstall --system --all --noninteractive || true
    flatpak uninstall --user --all --noninteractive || true

    # Clear Flatpak state so the git history starts fresh.
    rm -f "$REAL_HOME/.local/share/mirror-os/state/flatpak-apps.list"

    # Reset the system stamp so mirror-os-flatpak-init.service reinstalls default apps on next boot.
    sudo rm -f /var/lib/mirror-os/.flatpaks-installed
    echo "  → Default apps will be reinstalled by mirror-os-flatpak-init.service on next boot."
fi

# ── COSMIC reset ──────────────────────────────────────────────────────────────
if $DO_COSMIC; then
    echo "→ Resetting COSMIC desktop settings..."
    sudo rm -rf "$REAL_HOME/.config/cosmic"
    cp -r /usr/share/cosmic "$REAL_HOME/.config/cosmic"
    chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/cosmic"
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
