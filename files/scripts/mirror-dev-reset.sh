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
echo "  - COSMIC desktop environment settings"
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
git -C "$HM_DIR" init
git -C "$HM_DIR" config user.email "user@mirror-os.local"
git -C "$HM_DIR" config user.name "Mirror OS User"
git -C "$HM_DIR" add .

# ── Step 10: Expire old Home Manager generations ──────────────────────────────
echo "→ Expiring old Home Manager generations..."
home-manager expire-generations "-0 days" || true

# ── Step 11: Re-apply fresh Home Manager config ───────────────────────────────
echo "→ Re-applying fresh Home Manager config..."
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"
cd "$HM_DIR"
nix run 'github:nix-community/home-manager' -- switch --flake ".#$REAL_USER"

# ── Step 12: Reset COSMIC DE settings ─────────────────────────────────────────
echo "→ Resetting COSMIC DE settings..."
rm -rf "$REAL_HOME/.config/cosmic"

# ── Step 13: Done ─────────────────────────────────────────────────────────────
echo "Reset complete. Please log out and back in for COSMIC settings to take full effect."
