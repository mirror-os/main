FROM quay.io/fedora-ostree-desktops/cosmic-atomic:43

# Create /nix mountpoint for the Nix package manager.
# This must exist in the image because the root filesystem is read-only
# at runtime (composefs) and cannot be modified by users.
RUN mkdir -p /nix

# Add RPM Fusion free and nonfree repositories.
# These are required for multimedia codecs and proprietary drivers.
RUN rpm-ostree install \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm && \
    ostree container commit

# Download freeworld replacements as local RPM files, then pass them directly
# to rpm-ostree override replace. This is required because non-local replacement
# overrides are not supported in container builds — packages must be present
# on disk before the override can be applied.
RUN dnf download \
    --repo=rpmfusion-free \
    --repo=rpmfusion-free-updates \
    --destdir=/tmp/codec-overrides \
    ffmpeg \
    ffmpeg-libs \
    libavcodec-freeworld \
    mesa-va-drivers && \
    rpm-ostree override replace /tmp/codec-overrides/*.rpm && \
    rm -rf /tmp/codec-overrides && \
    ostree container commit

# Install remaining multimedia codecs that have no conflicts with the base image.
# gstreamer1-plugin-va replaces the deprecated gstreamer1-vaapi on Fedora 40+.
RUN rpm-ostree install \
    gstreamer1-plugins-base \
    gstreamer1-plugins-good \
    gstreamer1-plugins-good-extras \
    gstreamer1-plugins-bad-free \
    gstreamer1-plugins-bad-free-extras \
    gstreamer1-plugins-bad-freeworld \
    gstreamer1-plugins-ugly \
    gstreamer1-plugin-libav \
    gstreamer1-plugin-va && \
    ostree container commit

# Install the Mirror OS cosign public key used to verify image signatures.
# The matching private key is stored as a GitHub Actions secret and never
# committed to the repository.
COPY files/cosign.pub /etc/pki/mirror-os/cosign.pub

# Set the container signature verification policy.
# Rejects all images by default, and only allows Mirror OS images
# that are signed with our cosign key.
COPY files/policy.json /etc/containers/policy.json

# Tell the container runtime to look for cosign signatures stored as
# OCI attachments in the registry, which is how our GitHub Actions
# workflow pushes them.
COPY files/registries.d/mirror-os.yaml /etc/containers/registries.d/mirror-os.yaml

# Install the first-boot Nix installer script and its systemd service.
# The service runs once on first boot (ConditionFirstBoot=yes) and
# installs the Nix package manager via the Determinate Systems installer.
# It will never run again on subsequent boots.
COPY files/scripts/install-nix.sh /usr/libexec/mirror-os/install-nix.sh
COPY files/systemd/system/install-nix.service /usr/lib/systemd/system/install-nix.service
RUN chmod +x /usr/libexec/mirror-os/install-nix.sh && \
    systemctl enable install-nix.service