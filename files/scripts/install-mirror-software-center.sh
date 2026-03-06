#!/usr/bin/env bash
# Install Mirror OS Software Center binary from GHCR into the image.
# Runs during BlueBuild image construction as a script module.
set -oue pipefail

IMAGE="ghcr.io/mirror-os/mirror-software-center:latest"

echo "=== Installing Mirror OS Software Center ==="

# Pull image into a local OCI directory for extraction
mkdir -p /tmp/mirror-sc-oci
skopeo copy --insecure-policy "docker://${IMAGE}" "oci:/tmp/mirror-sc-oci"

# Extract the single layer (scratch image has one layer)
LAYER=$(ls /tmp/mirror-sc-oci/blobs/sha256/ | grep -v '\.json' | head -1)
mkdir -p /tmp/mirror-sc-extract
tar -xf "/tmp/mirror-sc-oci/blobs/sha256/${LAYER}" -C /tmp/mirror-sc-extract 2>/dev/null || true

# Find the binary (may be in ./usr/bin/ or direct path)
if [ -f /tmp/mirror-sc-extract/usr/bin/mirror-software-center ]; then
    install -Dm755 /tmp/mirror-sc-extract/usr/bin/mirror-software-center \
        /usr/bin/mirror-software-center
else
    echo "ERROR: mirror-software-center binary not found in image layer"
    exit 1
fi

# Install desktop file
if [ -d /tmp/mirror-sc-extract/usr/share/applications ]; then
    cp -r /tmp/mirror-sc-extract/usr/share/applications/. /usr/share/applications/
fi

# Install icons
if [ -d /tmp/mirror-sc-extract/usr/share/icons ]; then
    cp -r /tmp/mirror-sc-extract/usr/share/icons/. /usr/share/icons/
fi

rm -rf /tmp/mirror-sc.oci /tmp/mirror-sc-oci /tmp/mirror-sc-extract

echo "=== Mirror OS Software Center installed successfully ==="
