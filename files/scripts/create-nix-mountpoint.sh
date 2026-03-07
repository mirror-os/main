#!/bin/bash
set -euo pipefail

# Create the /nix mountpoint in the image layer.
# The root filesystem is read-only at runtime (composefs), so this directory
# must be pre-created here — it cannot be created by the user after booting.
mkdir -p /nix
chmod 755 /nix
