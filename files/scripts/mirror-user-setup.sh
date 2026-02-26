#!/usr/bin/env bash
# Mirror OS per-user first-login Home Manager setup.
# Runs as the user on their first login via systemd user service.
# ConditionPathExists on the service prevents re-runs.
set -euo pipefail

SYSTEM_HM_DIR="/usr/share/mirror-os/home-manager"
HM_DIR="$HOME/.config/home-manager"
NIX_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix.sh"

log() { echo "[mirror-user-setup] $*"; }

# ── Verify Nix is available ───────────────────────────────────────────────────
if [[ ! -f "$NIX_PROFILE" ]]; then
  log "ERROR: Nix not found at $NIX_PROFILE. Is install-nix.service complete?"
  exit 1
fi
source "$NIX_PROFILE"
export PATH="$HOME/.nix-profile/bin:/nix/var/nix/profiles/default/bin:$PATH"

# ── Enable flakes ─────────────────────────────────────────────────────────────
NIX_CONF_DIR="$HOME/.config/nix"
mkdir -p "$NIX_CONF_DIR"
if ! grep -q "experimental-features" "$NIX_CONF_DIR/nix.conf" 2>/dev/null; then
  echo "experimental-features = nix-command flakes" > "$NIX_CONF_DIR/nix.conf"
fi

# ── Scaffold Home Manager config ──────────────────────────────────────────────
log "Scaffolding Home Manager config for $USER..."
mkdir -p "$HM_DIR"

sed \
  -e "s|__USERNAME__|$USER|g" \
  -e "s|__HOMEDIR__|$HOME|g" \
  "$SYSTEM_HM_DIR/flake.template.nix" > "$HM_DIR/flake.nix"

sed \
  -e "s|__USERNAME__|$USER|g" \
  -e "s|__HOMEDIR__|$HOME|g" \
  "$SYSTEM_HM_DIR/home.template.nix" > "$HM_DIR/home.nix"

cp "$SYSTEM_HM_DIR/default.nix" "$HM_DIR/mirror-os-defaults.nix"

# ── Initialise git repo ───────────────────────────────────────────────────────
git -C "$HM_DIR" init -b main
git -C "$HM_DIR" config user.email "user@mirror-os.local"
git -C "$HM_DIR" config user.name "Mirror OS User"
git -C "$HM_DIR" add .
git -C "$HM_DIR" commit -m "initial"

# ── Run home-manager switch ───────────────────────────────────────────────────
log "Running home-manager switch (this may take a few minutes on first run)..."
cd "$HM_DIR"
nix run 'github:nix-community/home-manager' -- switch --flake ".#$USER"

log "User setup complete."