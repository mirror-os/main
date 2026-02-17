FROM quay.io/fedora-ostree-desktops/cosmic-atomic:43

# Pre-create /nix mountpoint for Nix package manager
RUN mkdir -p /nix