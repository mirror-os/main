FROM quay.io/fedora-ostree-desktops/cosmic-atomic:43

# Create /nix mountpoint for the Nix package manager.
# This must exist in the image because the root filesystem is read-only
# at runtime (composefs) and cannot be modified by users.
RUN mkdir -p /nix

# Add RPM Fusion free and nonfree repositories.
# These are required for freeworld codec replacements and future driver support.
RUN rpm-ostree install \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-43.noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-43.noarch.rpm && \
    ostree container commit

# Remove the codec-restricted free variants from the base image and install
# the full freeworld replacements in a single transaction using --install.
# This avoids the conflict that occurs when rpm-ostree tries to install
# freeworld packages while their free counterparts are still present.
RUN rpm-ostree override remove \
    ffmpeg-free \
    libavcodec-free \
    libavdevice-free \
    libavfilter-free \
    libavformat-free \
    libavutil-free \
    libpostproc-free \
    libswresample-free \
    libswscale-free \
    --install=ffmpeg \
    --install=ffmpeg-libs \
    --install=libavcodec-freeworld && \
    ostree container commit

# Replace mesa-va-drivers with the freeworld variant to unlock H.264/HEVC
# hardware decoding on Intel and AMD GPUs via VA-API.
# --arch=x86_64 prevents dnf from downloading the i686 variant, which has
# an unresolvable spirv-tools-libs dependency in the container build context.
RUN dnf download \
    --arch=x86_64 \
    --repo=rpmfusion-free \
    --repo=rpmfusion-free-updates \
    --destdir=/tmp/mesa-overrides \
    mesa-va-drivers && \
    rpm-ostree override replace /tmp/mesa-overrides/*.rpm && \
    rm -rf /tmp/mesa-overrides && \
    ostree container commit

# Install remaining multimedia codecs that have no conflicts with the base image.
# VA-API GStreamer support is included in gstreamer1-plugins-bad-free on Fedora 43.
RUN rpm-ostree install \
    gstreamer1-plugins-base \
    gstreamer1-plugins-good \
    gstreamer1-plugins-good-extras \
    gstreamer1-plugins-bad-free \
    gstreamer1-plugins-bad-free-extras \
    gstreamer1-plugins-bad-freeworld \
    gstreamer1-plugins-ugly \
    gstreamer1-plugin-libav && \
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