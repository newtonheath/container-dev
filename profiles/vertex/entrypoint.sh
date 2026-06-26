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
  "env": {
    "CLAUDE_CODE_USE_VERTEX": "${CLAUDE_CODE_USE_VERTEX:-1}",
    "ANTHROPIC_VERTEX_PROJECT_ID": "${ANTHROPIC_VERTEX_PROJECT_ID}",
    "CLOUD_ML_REGION": "${CLOUD_ML_REGION:-global}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-5@20250929",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5@20251001"
  }
}
SETTINGS

exec /usr/sbin/sshd -D
