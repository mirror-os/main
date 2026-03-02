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
    echo "  --flatpaks  Remove all Flatpaks and reinstall default apps"
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
if $DO_FLATPAKS; then echo "  - All Flatpaks (default apps will be reinstalled)"; fi
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
DEFAULT_APPS_LIST="/usr/share/mirror-os/default-apps.list"

NIX_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix.sh"
# shellcheck source=/dev/null
source "$NIX_PROFILE"
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

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

    # Clear state so exclusion tracking starts fresh.
    rm -f "$REAL_HOME/.local/share/mirror-os/state/flatpak-apps.list"
    mkdir -p "$REAL_HOME/.config/mirror-os"
    > "$REAL_HOME/.config/mirror-os/excluded-apps.list"

    # Reinstall default apps at system scope from the authoritative list.
    # On a production system this happens automatically via uBuild's
    # default-flatpaks module on first boot after a rebase; this step
    # replicates that for development resets without requiring a rebase.
    echo "→ Reinstalling default apps at system scope..."
    if [ -f "$DEFAULT_APPS_LIST" ]; then
        while IFS= read -r appid; do
            # Skip blank lines and comments
            [[ -z "$appid" || "$appid" == \#* ]] && continue
            echo "  → Installing $appid..."
            sudo flatpak install --system --noninteractive --or-update "$appid" 2>/dev/null || \
                echo "  → WARNING: Could not install $appid (check flatpak remotes)"
        done < "$DEFAULT_APPS_LIST"
        echo "  → Default apps reinstalled."
    else
        echo "  → WARNING: $DEFAULT_APPS_LIST not found; default apps not reinstalled."
    fi
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
