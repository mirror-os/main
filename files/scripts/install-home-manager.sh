#!/usr/bin/env bash
set -euo pipefail

# Find the primary human user (UID >= 1000, has a home directory)
PRIMARY_USER=$(getent passwd | awk -F: '$3 >= 1000 && $6 ~ /^\/home/ {print $1; exit}')

if [[ -z "$PRIMARY_USER" ]]; then
    echo "install-home-manager: no primary user found, exiting"
    exit 0
fi

HOME_DIR=$(getent passwd "$PRIMARY_USER" | cut -d: -f6)
CONFIG_DIR="$HOME_DIR/.config/home-manager"
FLAKE_TEMPLATE="/usr/share/mirror-os/home-manager/flake.template.nix"
HOME_TEMPLATE="/usr/share/mirror-os/home-manager/home.template.nix"

run_as_user() {
    runuser -l "$PRIMARY_USER" -c "$1"
}

echo "install-home-manager: setting up Home Manager for $PRIMARY_USER"

# Enable flakes for this user
run_as_user "mkdir -p '$HOME_DIR/.config/nix'"
run_as_user "echo 'experimental-features = nix-command flakes' > '$HOME_DIR/.config/nix/nix.conf'"

# Create the home-manager config directory and populate it from templates
# if the user hasn't already created their own config
if [[ ! -f "$CONFIG_DIR/flake.nix" ]]; then
    echo "install-home-manager: writing default flake config for $PRIMARY_USER"
    run_as_user "mkdir -p '$CONFIG_DIR'"

    sed \
        -e "s|__USERNAME__|$PRIMARY_USER|g" \
        -e "s|__HOMEDIR__|$HOME_DIR|g" \
        "$FLAKE_TEMPLATE" > "$CONFIG_DIR/flake.nix"

    sed \
        -e "s|__USERNAME__|$PRIMARY_USER|g" \
        -e "s|__HOMEDIR__|$HOME_DIR|g" \
        "$HOME_TEMPLATE" > "$CONFIG_DIR/home.nix"

    chown "$PRIMARY_USER:$PRIMARY_USER" "$CONFIG_DIR/flake.nix"
    chown "$PRIMARY_USER:$PRIMARY_USER" "$CONFIG_DIR/home.nix"

    # Flakes require the config directory to be a git repo
    run_as_user "cd '$CONFIG_DIR' && git init && git add ."
fi

# Install Home Manager and apply the configuration
run_as_user "source /nix/var/nix/profiles/default/etc/profile.d/nix.sh && \
    cd '$CONFIG_DIR' && \
    nix run home-manager/master -- switch --flake '.#$PRIMARY_USER'"

echo "install-home-manager: done"