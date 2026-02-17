FROM quay.io/fedora-ostree-desktops/cosmic:latest

# Pre-create /nix mountpoint for Nix package manager
RUN mkdir -p /nix