#!/usr/bin/env bash
# Mirror OS first-boot Nix setup
# Triggered by mirror-nix-setup.service on first boot and after rebases.
# Stamp file: /var/lib/mirror-os/nix-installed

set -euo pipefail

STAMP="/var/lib/mirror-os/nix-installed"
SYSTEM_HM_DIR="/usr/share/mirror-os/home-manager"
LOG_TAG="mirror-nix-setup"

log() { echo "[mirror-nix-setup] $*"; }

# ── Already done — bail out early ────────────────────────────────────────────
if [[ -f "$STAMP" ]]; then
  log "Stamp present, skipping."
  exit 0
fi

# ── Determine the real logged-in user (not root) ──────────────────────────────
# The service runs as root; we need the actual desktop user.
REAL_USER=$(loginctl list-users --no-legend | awk '{print $2}' | head -1)
if [[ -z "$REAL_USER" ]]; then
  # Fallback: first non-system user in /home
  REAL_USER=$(ls /home | head -1)
fi
REAL_HOME="/home/$REAL_USER"
log "Configuring for user: $REAL_USER ($REAL_HOME)"

# ── Install Home Manager (standalone) ────────────────────────────────────────
log "Installing Home Manager..."
sudo -u "$REAL_USER" nix run nixpkgs#home-manager -- --version 2>/dev/null \
  || sudo -u "$REAL_USER" nix-channel --add \
       https://github.com/nix-community/home-manager/archive/master.tar.gz home-manager

# ── Scaffold user config (only if it doesn't already exist) ──────────────────
HM_DIR="$REAL_HOME/.config/home-manager"

if [[ ! -f "$HM_DIR/flake.nix" ]]; then
  log "Scaffolding flake.nix..."
  mkdir -p "$HM_DIR"
  sed "s/__USERNAME__/$REAL_USER/g" \
    "$SYSTEM_HM_DIR/flake.template.nix" > "$HM_DIR/flake.nix"
  chown "$REAL_USER:$REAL_USER" "$HM_DIR/flake.nix"
fi

if [[ ! -f "$HM_DIR/home.nix" ]]; then
  log "Scaffolding home.nix..."
  mkdir -p "$HM_DIR"
  sed "s/__USERNAME__/$REAL_USER/g" \
    "$SYSTEM_HM_DIR/home.template.nix" > "$HM_DIR/home.nix"
  chown "$REAL_USER:$REAL_USER" "$HM_DIR/home.nix"
fi
chown -R "$REAL_USER:$REAL_USER" "$HM_DIR"

# ── Run home-manager switch ───────────────────────────────────────────────────
log "Running home-manager switch..."
sudo -u "$REAL_USER" bash -c "
  cd $HM_DIR
  nix run home-manager/master -- switch --flake .#$REAL_USER
"

# ── Set zsh as the default shell ─────────────────────────────────────────────
ZSH_PATH=$(sudo -u "$REAL_USER" bash -c 'echo $HOME/.nix-profile/bin/zsh')
if [[ -x "$ZSH_PATH" ]]; then
  log "Setting zsh as default shell..."
  if ! grep -q "$ZSH_PATH" /etc/shells; then
    echo "$ZSH_PATH" >> /etc/shells
  fi
  chsh -s "$ZSH_PATH" "$REAL_USER"
else
  log "Warning: zsh not found at $ZSH_PATH, shell not changed."
fi

# ── Write stamp ───────────────────────────────────────────────────────────────
mkdir -p /var/lib/mirror-os
touch "$STAMP"
log "Done."
