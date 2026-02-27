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
    echo "  --hm        Reset Home Manager config and rebuild Nix environment"
    echo "  --flatpaks  Remove all Flatpaks and reinstall blessed apps"
    echo "  --cosmic    Reset COSMIC desktop settings"
    echo "  --init      Remove .init-complete (mirror-init re-runs on next boot)"
    echo "  --full      All of the above"
    echo "  --help      Show this message"
    echo ""
    echo "No arguments: equivalent to --hm --flatpaks --cosmic"
}

# ── Parse arguments ───────────────────────────────────────────────────────────
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
        --hm)       DO_HM=true ;;
        --flatpaks) DO_FLATPAKS=true ;;
        --cosmic)   DO_COSMIC=true ;;
        --init)     DO_INIT=true ;;
        --full)     DO_HM=true; DO_FLATPAKS=true; DO_COSMIC=true; DO_INIT=true ;;
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
if $DO_HM;       then echo "  - Home Manager config and generations"; fi
if $DO_FLATPAKS; then echo "  - All Flatpaks (blessed apps will be reinstalled)"; fi
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

# ── Home Manager reset ────────────────────────────────────────────────────────
if $DO_HM; then
    echo "→ Resetting Home Manager config..."
    rm -rf "$HM_DEST"
    mkdir -p "$HM_DEST"

    for template in flake.nix home.nix home-mirror-apps.nix home-user.nix; do
        sed "s/__USERNAME__/$REAL_USER/g" \
            "$TEMPLATES_DIR/${template}.template" \
            > "$HM_DEST/$template"
    done

    git -C "$HM_DEST" init -b main
    git -C "$HM_DEST" config user.email "user@mirror-os.local"
    git -C "$HM_DEST" config user.name "Mirror OS User"
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
    echo "→ Removing all system Flatpak apps (requires sudo)..."
    flatpak list --system --app --columns=application 2>/dev/null \
        | xargs -r sudo flatpak uninstall --system -y --noninteractive || true

    echo "→ Removing all user Flatpak apps..."
    flatpak list --user --app --columns=application 2>/dev/null \
        | xargs -r flatpak uninstall --user -y --noninteractive || true

    # Clear state so mirror-sync reinstalls blessed apps fresh instead of
    # treating the removals above as user-initiated exclusions.
    rm -f "$REAL_HOME/.local/share/mirror-os/state/flatpak-apps.list"
    > "$REAL_HOME/.config/mirror-os/excluded-apps.list"

    echo "→ Reinstalling blessed apps via mirror-sync..."
    systemctl --user start mirror-os-sync.service 2>/dev/null || true
    echo "  → Blessed apps are installing in the background."
    WATCH_CMD="journalctl --user -u mirror-os-sync.service -f"
    if command -v cosmic-term &>/dev/null; then
        cosmic-term -- sh -c "$WATCH_CMD" &
    elif command -v gnome-terminal &>/dev/null; then
        gnome-terminal -- sh -c "$WATCH_CMD" &
    elif command -v xterm &>/dev/null; then
        xterm -e sh -c "$WATCH_CMD" &
    else
        echo "  → Check progress with: $WATCH_CMD"
    fi
fi

# ── COSMIC reset ──────────────────────────────────────────────────────────────
if $DO_COSMIC; then
    echo "→ Resetting COSMIC desktop settings..."
    sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/cosmic" 2>/dev/null || true
    rm -rf "$REAL_HOME/.config/cosmic"
    echo "  → COSMIC config cleared. Desktop will return to defaults on next login."
fi

# ── Init marker removal ───────────────────────────────────────────────────────
if $DO_INIT; then
    echo "→ Removing init-complete marker..."
    rm -f "$REAL_HOME/.local/share/mirror-os/.init-complete"
    echo "  → mirror-init will run on next boot."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo "Reset complete. Please reboot for all changes to take effect."
