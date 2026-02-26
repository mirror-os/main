#!/usr/bin/env bash
set -euo pipefail

# Mirror OS Development Reset Script
# Resets the user environment to first-boot state for testing workflows.
# Runs as the regular user (not root).

# ── Step 1: Warning + confirmation ───────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "WARNING: Mirror OS Development Reset"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This will reset your Mirror OS installation to first-boot state."
echo ""
echo "The following will be DELETED:"
echo "  - All Home Manager config and generations"
echo ""
echo "Press Ctrl+C to cancel, or Enter to continue..."
read -r

# ── Step 2: Determine current user and home directory ─────────────────────────
REAL_USER=$(id -un)
REAL_HOME="$HOME"

# ── Step 3: Source Nix profile ────────────────────────────────────────────────
NIX_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix.sh"
# shellcheck source=/dev/null
source "$NIX_PROFILE"

# ── Step 4: Status line ───────────────────────────────────────────────────────
echo "→ Resetting Home Manager config..."

# ── Step 5: Wipe and recreate ~/.config/home-manager/ ────────────────────────
rm -rf "$REAL_HOME/.config/home-manager"
mkdir -p "$REAL_HOME/.config/home-manager"

# ── Step 6: Scaffold flake.nix from system template ──────────────────────────
sed \
  -e "s|__USERNAME__|$REAL_USER|g" \
  -e "s|__HOMEDIR__|$REAL_HOME|g" \
  /usr/share/mirror-os/home-manager/flake.template.nix \
  > "$REAL_HOME/.config/home-manager/flake.nix"

# ── Step 7: Scaffold home.nix from system template ───────────────────────────
sed \
  -e "s|__USERNAME__|$REAL_USER|g" \
  -e "s|__HOMEDIR__|$REAL_HOME|g" \
  /usr/share/mirror-os/home-manager/home.template.nix \
  > "$REAL_HOME/.config/home-manager/home.nix"

# ── Step 8: Copy mirror-os-defaults.nix ──────────────────────────────────────
cp /usr/share/mirror-os/home-manager/default.nix \
   "$REAL_HOME/.config/home-manager/mirror-os-defaults.nix"

# ── Step 9: Initialise git repo and configure identity ───────────────────────
HM_DIR="$REAL_HOME/.config/home-manager"
git -C "$HM_DIR" init -b main
git -C "$HM_DIR" config user.email "user@mirror-os.local"
git -C "$HM_DIR" config user.name "Mirror OS User"
git -C "$HM_DIR" add .
git -C "$HM_DIR" commit -m "initial"

# ── Step 10: Expire old Home Manager generations ──────────────────────────────
echo "→ Expiring old Home Manager generations..."
home-manager expire-generations "-0 days" || true

# ── Step 11: Re-apply fresh Home Manager config ───────────────────────────────
echo "→ Re-applying fresh Home Manager config..."
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
cd "$HM_DIR"
systemctl --user reset-failed flatpak-managed-install.service 2>/dev/null || true
nix run 'github:nix-community/home-manager' -- switch --flake ".#$REAL_USER" || {
  echo "→ Home Manager switch completed with warnings (flatpak timeout is expected on first run)."
}

# ── Step 12: Reset user Flatpaks ──────────────────────────────────────────────
echo "→ Resetting user Flatpaks..."
echo "  → Removing all user-installed Flatpaks..."
flatpak list --user --app --columns=application 2>/dev/null | while IFS= read -r app; do
  if [ -n "$app" ]; then
    echo "    → Removing user Flatpak: $app"
    flatpak uninstall --user --noninteractive "$app" || true
  fi
done
echo "  → Restarting Flatpak install service to reinstall defaults..."
systemctl --user reset-failed flatpak-managed-install.service 2>/dev/null || true
systemctl --user start flatpak-managed-install.service 2>/dev/null || true
echo "  → Flatpaks are installing in the background. Check progress with:"
echo "     journalctl --user -u flatpak-managed-install.service -f"

# ── Step 13: Reset COSMIC desktop settings ────────────────────────────────────
echo "→ Resetting COSMIC desktop settings..."
sudo rm -rf "$REAL_HOME/.config/cosmic"
echo "  → COSMIC config cleared. Desktop will return to defaults on next login."

# ── Step 14: Done ─────────────────────────────────────────────────────────────
echo "Reset complete. Please log out or reboot for COSMIC settings to take effect."
