FROM quay.io/fedora-ostree-desktops/cosmic-atomic:43

# Pre-create /nix mountpoint for Nix package manager
RUN mkdir -p /nix

# Fetch Sigstore roots for cosign verification
RUN mkdir -p /etc/pki/sigstore && \
    curl -o /etc/pki/sigstore/roots.pem https://fulcio.sigstore.dev/api/v1/rootCert && \
    curl -o /etc/pki/sigstore/rekor.pem https://rekor.sigstore.dev/api/v1/log/publicKey

# Add cosign verification policy for Mirror OS updates
COPY files/policy.json /etc/containers/policy.json