FROM quay.io/fedora-ostree-desktops/cosmic-atomic:43

# Pre-create /nix mountpoint for Nix package manager
RUN mkdir -p /nix

# Add cosign verification policy for Mirror OS updates
COPY files/policy.json /etc/containers/policy.json