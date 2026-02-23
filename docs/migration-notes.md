# Migration Notes: Containerfile → BlueBuild

This document is the permanent reference for the migration from a raw `Containerfile` build system to BlueBuild. The files that were deleted (`Containerfile` and `.github/workflows/build.yml`) are reproduced in full below. **BlueBuild is now the source of truth.** Do not use these for anything other than historical reference.

---

## Original Containerfile

```dockerfile
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

# Install distrobox to allow running any Linux distribution inside a container
# with full desktop integration (exported icons, applications, and terminal access).
# Baked into the image layer so it is available before Nix is initialised.
RUN rpm-ostree install \
    distrobox && \
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

# Ship the Mirror OS Home Manager defaults at a read-only system path.
# This includes the default.nix module (zsh, NixVim, htop, nix-flatpak) as
# well as the flake.nix and home.nix templates that are scaffolded once into
# the user's ~/.config/home-manager/ on first boot. Image updates replace
# this directory; user files in /home are never touched.
COPY files/home-manager/ /usr/share/mirror-os/home-manager/

# Install the Home Manager setup script and its systemd service.
# The service runs after Nix is ready (requires install-nix.service) and uses
# a stamp file at /var/lib/mirror-os/nix-hm-installed to ensure it only
# performs the full setup once. On rebase it re-runs to apply any updated
# Mirror OS defaults while leaving the user's own home.nix untouched.
COPY files/scripts/mirror-nix-setup.sh /usr/libexec/mirror-os/mirror-nix-setup.sh
COPY files/systemd/system/mirror-nix-setup.service /usr/lib/systemd/system/mirror-nix-setup.service
RUN chmod +x /usr/libexec/mirror-os/mirror-nix-setup.sh && \
    systemctl enable mirror-nix-setup.service
```

---

## Original `.github/workflows/build.yml`

```yaml
name: Build Mirror OS

on:
  push:
    branches: [main]
  schedule:
    - cron: '0 0 * * 1'

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
      id-token: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install cosign
        uses: sigstore/cosign-installer@v3

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push
        id: build
        uses: docker/build-push-action@v5
        with:
          context: .
          file: Containerfile
          push: true
          tags: ghcr.io/mirror-os/mirror-os:latest

      - name: Sign image
        env:
          COSIGN_PRIVATE_KEY: ${{ secrets.COSIGN_PRIVATE_KEY }}
        run: |
          cosign sign --yes --key env://COSIGN_PRIVATE_KEY \
            --tlog-upload=false \
            ghcr.io/mirror-os/mirror-os@${{ steps.build.outputs.digest }}
```

---

## Architectural Decision Notes

### Why `/nix` must be pre-created in the image

Fedora Atomic uses composefs, which makes the root filesystem read-only at runtime. A user or service cannot run `mkdir /nix` after booting — the operation will fail with a read-only filesystem error. The `/nix` directory therefore has to exist as an empty mountpoint inside the image layer itself, where the Nix daemon can bind-mount the actual Nix store on top of it at runtime. The Determinate Systems installer expects this directory to exist before it runs.

### Why the freeworld codec override uses a single `override remove ... --install` transaction

Fedora's base Atomic images ship "free" variants of ffmpeg and related libraries (`ffmpeg-free`, `libavcodec-free`, etc.) that are intentionally crippled to comply with distribution policies. The RPM Fusion freeworld replacements (`ffmpeg`, `libavcodec-freeworld`) conflict with these packages by providing the same shared libraries. Attempting to install the freeworld packages while the free counterparts are still present causes an `rpm-ostree` conflict error. The solution is to remove and install in a single atomic transaction using `override remove ... --install`, which resolves the conflict within one operation.

### Why mesa-va-drivers needs a separate `dnf download` step

The `rpm-ostree override replace` command for mesa-va-drivers cannot use BlueBuild's standard `replace:` module field (which is designed for COPR repositories) because the mesa freeworld package is in the standard RPM Fusion free repo, not COPR. More importantly, simply fetching the RPM by name would also pull the i686 variant, which has an unresolvable `spirv-tools-libs` dependency in the container build context. The `--arch=x86_64` flag on `dnf download` prevents this, but that flag is not exposed through the BlueBuild rpm-ostree module. A build-time script is therefore required.

### Why the stamp-file approach is used for the first-boot services

The `install-nix.service` checks for `/var/lib/mirror-os/nix-installed` before running, and writes that file upon success. The `mirror-nix-setup.service` uses a similar stamp at `/var/lib/mirror-os/nix-hm-installed`. This prevents the setup from re-running on every boot and from running again after a routine image rebase. On a fresh install neither stamp exists, so both services run. On subsequent boots they are skipped. The `/var/lib/` directory persists across reboots on Atomic systems because it is part of the writable stateful layer.

### Why static cosign key signing was chosen over keyless

The `policy.json` shipped in the image uses `sigstoreSigned` with an explicit `keyPath` pointing to `files/cosign.pub`. Keyless (OIDC-based) cosign signing produces certificates tied to the GitHub Actions identity rather than a static key, but the container runtime's `sigstoreSigned` policy type requires a stable, known public key at verification time. Keyless verification would require a different policy type and a trust root pointing to Fulcio, which adds complexity and an external dependency to every container pull. Static key signing keeps the verification self-contained and registry-agnostic.
