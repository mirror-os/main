FROM quay.io/fedora-ostree-desktops/cosmic-atomic:43

RUN mkdir -p /nix

RUN mkdir -p /etc/pki/sigstore && \
    curl -o /etc/pki/sigstore/roots.pem https://fulcio.sigstore.dev/api/v1/rootCert && \
    curl -o /etc/pki/sigstore/rekor.pem https://rekor.sigstore.dev/api/v1/log/publicKey

COPY files/cosign.pub /etc/pki/mirror-os/cosign.pub
COPY files/policy.json /etc/containers/policy.json
COPY files/registries.d/mirror-os.yaml /etc/containers/registries.d/mirror-os.yaml