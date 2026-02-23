#!/usr/bin/env bash
set -euo pipefail

# Mirror OS Development Reset Script
# Resets the system to first-boot state for testing workflows

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚠️  WARNING: Mirror OS Development Reset"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "This will reset your Mirror OS installation to first-boot state."
echo ""
echo "The following will be DELETED:"
echo "  • All user Nix packages"
echo "  • Home Manager customizations"
echo "  • COSMIC desktop environment settings"
echo ""
echo "Press Ctrl+C to cancel, or Enter to continue..."
read -r

echo ""
echo "→ Resetting Home Manager config..."
rm -rf ~/.config/home-manager
mkdir -p ~/.config/home-manager
cat > ~/.config/home-manager/home.nix << 'EOF'
{ pkgs, ... }: {
  imports = [ /usr/share/mirror-os/home-manager/default.nix ];
}
EOF
echo "  ✓ Home Manager config reset to base scaffold"

echo ""
echo "→ Wiping Nix Home Manager generations..."
home-manager expire-generations "-0 days"
echo "  ✓ All generations expired"

echo ""
echo "→ Re-applying fresh Home Manager config..."
home-manager switch
echo "  ✓ Home Manager config applied"

echo ""
echo "→ Resetting COSMIC desktop environment settings..."
if [ -d ~/.config/cosmic ]; then
  rm -rf ~/.config/cosmic
  echo "  ✓ COSMIC settings removed"
else
  echo "  ℹ No COSMIC settings found (already clean)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ Reset complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Please log out and back in for COSMIC settings to take full effect."
echo ""
