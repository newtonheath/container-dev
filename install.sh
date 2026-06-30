#!/usr/bin/env bash
set -euo pipefail

# Container-dev installation script
# Creates symlink to make 'container-dev' command available globally

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
TARGET="$BIN_DIR/container-dev"

echo "Installing container-dev..."

# Create ~/.local/bin if it doesn't exist
mkdir -p "$BIN_DIR"

# Create symlink
if [[ -L "$TARGET" || -f "$TARGET" ]]; then
  echo "Removing existing $TARGET"
  rm -f "$TARGET"
fi

ln -s "$SCRIPT_DIR/bin/container-dev" "$TARGET"
chmod +x "$SCRIPT_DIR/bin/container-dev"

echo "✓ Installed: $TARGET -> $SCRIPT_DIR/bin/container-dev"
echo ""

# Check if ~/.local/bin is in PATH
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "⚠️  Warning: $BIN_DIR is not in your PATH"
  echo ""
  echo "Add this to your ~/.bashrc or ~/.zshrc:"
  echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
else
  echo "✓ ~/.local/bin is in your PATH"
fi

# Test installation
if command -v container-dev >/dev/null 2>&1; then
  echo "✓ Installation successful!"
  echo ""
  echo "Usage:"
  echo "  container-dev start <profile> [--persistent]"
  echo "  container-dev stop <container-name>"
  echo "  container-dev list"
  echo "  container-dev persist"
  echo ""
  echo "Example:"
  echo "  cd ~/your/project"
  echo "  container-dev start claude"
  echo "  ssh claude-transient"
else
  echo "⚠️  Could not find 'container-dev' command"
  echo "You may need to restart your shell or run: source ~/.bashrc"
fi
