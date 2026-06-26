#!/usr/bin/env bash
# Copy the mounted public key into place with correct ownership for sshd.
if [[ -f /tmp/pubkey/authorized_keys ]]; then
  cp /tmp/pubkey/authorized_keys /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

# Pre-seed Claude Code settings so the first-run wizard is skipped.
mkdir -p /root/.claude
cat > /root/.claude/settings.json <<SETTINGS
{
  "theme": "dark",
  "model": "claude-sonnet-4-5-20250514",
  "env": {
    "ANTHROPIC_API_KEY": "${ANTHROPIC_API_KEY}"
  }
}
SETTINGS

echo 'cd /workspace' >> /root/.bashrc

exec /usr/sbin/sshd -D
