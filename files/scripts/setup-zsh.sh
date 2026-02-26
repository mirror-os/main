#!/usr/bin/env bash
# Mirror OS — system-wide zsh configuration
# Runs at image build time via BlueBuild script module.
set -euo pipefail

# ── Register zsh in /etc/shells ───────────────────────────────────────────────
if ! grep -q "^/usr/bin/zsh$" /etc/shells; then
  echo "/usr/bin/zsh" >> /etc/shells
fi

# ── Set zsh as default shell for new users ────────────────────────────────────
# This affects useradd so any new user created on the system gets zsh.
sed -i 's|^SHELL=.*|SHELL=/usr/bin/zsh|' /etc/default/useradd

# ── Create system-wide zsh config sourcing plugins ───────────────────────────
mkdir -p /etc/zshrc.d
cat > /etc/zshrc.d/mirror-os.zsh << 'EOF'
# Mirror OS — system zsh defaults
# Autosuggestions
if [[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]]; then
  source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
fi
# Syntax highlighting (must be last)
if [[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
fi
EOF
