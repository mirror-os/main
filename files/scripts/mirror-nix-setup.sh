#!/usr/bin/env bash
# Mirror OS first-boot Nix + Home Manager setup.
# Runs after install-nix.service. Stamp file prevents re-runs.
set -euo pipefail

STAMP="/var/lib/mirror-os/nix-installed"
SYSTEM_HM_DIR="/usr/share/mirror-os/home-manager"

log() { echo "[mirror-nix-setup] $*"; }

# ── Already done — bail out early ────────────────────────────────────────────
if [[ -f "$STAMP" ]]; then
  log "Stamp present, skipping."
  exit 0
fi

# ── Determine the real user ───────────────────────────────────────────────────
REAL_USER=$(loginctl list-users --no-legend | awk '{print $2}' | head -1)
if [[ -z "$REAL_USER" ]]; then
  REAL_USER=$(ls /home | head -1)
fi
REAL_HOME="/home/$REAL_USER"
log "Configuring for user: $REAL_USER ($REAL_HOME)"

# ── Source Nix so all nix commands are available ──────────────────────────────
NIX_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix.sh"
if [[ ! -f "$NIX_PROFILE" ]]; then
  log "ERROR: Nix profile not found at $NIX_PROFILE — is install-nix.service done?"
  exit 1
fi
# shellcheck source=/dev/null
source "$NIX_PROFILE"

# ── Enable flakes for this user ───────────────────────────────────────────────
NIX_CONF_DIR="$REAL_HOME/.config/nix"
mkdir -p "$NIX_CONF_DIR"
if ! grep -q "experimental-features" "$NIX_CONF_DIR/nix.conf" 2>/dev/null; then
  echo "experimental-features = nix-command flakes" > "$NIX_CONF_DIR/nix.conf"
fi
chown -R "$REAL_USER:$REAL_USER" "$NIX_CONF_DIR"

# ── Scaffold user config (only if not already present) ───────────────────────
HM_DIR="$REAL_HOME/.config/home-manager"

if [[ ! -f "$HM_DIR/flake.nix" ]]; then
  log "Scaffolding flake.nix..."
  mkdir -p "$HM_DIR"
  sed \
    -e "s|__USERNAME__|$REAL_USER|g" \
    -e "s|__HOMEDIR__|$REAL_HOME|g" \
    "$SYSTEM_HM_DIR/flake.template.nix" > "$HM_DIR/flake.nix"
fi

if [[ ! -f "$HM_DIR/home.nix" ]]; then
  log "Scaffolding home.nix..."
  mkdir -p "$HM_DIR"
  sed \
    -e "s|__USERNAME__|$REAL_USER|g" \
    -e "s|__HOMEDIR__|$REAL_HOME|g" \
    "$SYSTEM_HM_DIR/home.template.nix" > "$HM_DIR/home.nix"
fi

chown -R "$REAL_USER:$REAL_USER" "$HM_DIR"

# ── Initialise git repo (flakes require a git repo) ───────────────────────────
if [[ ! -d "$HM_DIR/.git" ]]; then
  log "Initialising git repo in $HM_DIR..."
  sudo -u "$REAL_USER" git -C "$HM_DIR" init
  sudo -u "$REAL_USER" git -C "$HM_DIR" add .
fi

# ── Run home-manager switch ───────────────────────────────────────────────────
log "Running home-manager switch..."
sudo -u "$REAL_USER" bash -c "
  source '$NIX_PROFILE'
  cd '$HM_DIR'
  nix run 'github:nix-community/home-manager' -- switch --flake '.#$REAL_USER'
"

# ── Set zsh as the default shell ─────────────────────────────────────────────
ZSH_PATH=$(sudo -u "$REAL_USER" bash -c "source '$NIX_PROFILE'; which zsh" 2>/dev/null || true)
if [[ -x "$ZSH_PATH" ]]; then
  log "Setting zsh as default shell: $ZSH_PATH"
  grep -qxF "$ZSH_PATH" /etc/shells || echo "$ZSH_PATH" >> /etc/shells
  chsh -s "$ZSH_PATH" "$REAL_USER"
else
  log "Warning: zsh not found in PATH, shell not changed."
fi

# ── Write stamp ───────────────────────────────────────────────────────────────
mkdir -p /var/lib/mirror-os
touch "$STAMP"
log "Done."