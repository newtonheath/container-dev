#!/usr/bin/env bash
# Copy the mounted public key into place with correct ownership for sshd.
if [[ -f /tmp/pubkey/authorized_keys ]]; then
  cp /tmp/pubkey/authorized_keys /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

# Pre-seed Claude Code settings. No API key — authentication is via browser OAuth.
# Credentials are stored in /root/.claude/ which is mounted as a persistent host volume.
mkdir -p /root/.claude
cat > /root/.claude/settings.json <<SETTINGS
{
  "theme": "dark",
  "model": "claude-sonnet-4-6"
}
SETTINGS

echo 'cd /workspace' >> /root/.bashrc

exec /usr/sbin/sshd -D
