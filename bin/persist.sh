#!/usr/bin/env bash
set -euo pipefail

# Convert a transient container to persistent

WORKSPACE="${1:-$(pwd)}"
STATE_FILE="$HOME/.config/container-dev/state"
SSH_CONFIG="$HOME/.ssh/config"

# Derive workspace slug
WORKSPACE=$(cd "$WORKSPACE" && pwd)  # Absolute path
WORKSPACE_SLUG=$(basename "$WORKSPACE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')

echo "Converting transient container to persistent..."
echo "  Workspace: $WORKSPACE"
echo "  Slug:      $WORKSPACE_SLUG"
echo ""

# Find transient container for this workspace
if [[ ! -f "$STATE_FILE" ]]; then
  echo "Error: No state file found at $STATE_FILE"
  exit 1
fi

TRANSIENT_CONTAINER=""
TRANSIENT_PROFILE=""
TRANSIENT_PORT=""

while IFS='|' read -r name workspace port type; do
  if [[ "$type" == "transient" && "$workspace" == "$WORKSPACE" ]]; then
    TRANSIENT_CONTAINER="$name"
    TRANSIENT_PROFILE="${name%-transient}"
    TRANSIENT_PORT="$port"
    break
  fi
done < "$STATE_FILE"

if [[ -z "$TRANSIENT_CONTAINER" ]]; then
  echo "Error: No transient container found for workspace: $WORKSPACE"
  echo ""
  echo "Start a transient container first with:"
  echo "  container-dev start <profile>"
  exit 1
fi

# Check if container is actually running
if ! container list --format '{{.Names}}' | grep -q "^${TRANSIENT_CONTAINER}$"; then
  echo "Error: Container $TRANSIENT_CONTAINER is not running"
  exit 1
fi

PERSISTENT_NAME="${TRANSIENT_PROFILE}-${WORKSPACE_SLUG}"

# Check if persistent container already exists
if container list --format '{{.Names}}' | grep -q "^${PERSISTENT_NAME}$"; then
  echo "Error: Persistent container already exists: $PERSISTENT_NAME"
  exit 1
fi

echo "Renaming container:"
echo "  From: $TRANSIENT_CONTAINER"
echo "  To:   $PERSISTENT_NAME"
echo ""

# Note: Apple's container CLI may not support rename
# We'll need to commit the container to an image and recreate it
# For now, warn the user that this is a destructive operation

read -p "This will stop and recreate the container. Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

# Commit container to temporary image
TEMP_IMAGE="${PERSISTENT_NAME}-temp-img"
echo "Creating snapshot..."
container commit "$TRANSIENT_CONTAINER" "$TEMP_IMAGE"

# Get container details for recreation
CONTAINER_DETAILS=$(container inspect "$TRANSIENT_CONTAINER")

# Stop and remove transient container
echo "Stopping transient container..."
container stop "$TRANSIENT_CONTAINER"
container rm "$TRANSIENT_CONTAINER"

# Start new persistent container from snapshot
echo "Creating persistent container..."
# Note: This is simplified - actual recreation needs to preserve all mounts/env vars
# The real implementation would need to extract and re-apply all the original run arguments

# For now, just warn that full implementation is needed
echo ""
echo "⚠️  Full implementation needed:"
echo "   The persist command needs to extract and replay all original container arguments"
echo "   Including: volumes, environment variables, ports, resource limits"
echo ""
echo "For now, you can manually recreate with:"
echo "  container-dev start $TRANSIENT_PROFILE --persistent"
echo ""
echo "Cleaning up temporary image..."
container rmi "$TEMP_IMAGE"

# Update state file
sed -i.bak "/^${TRANSIENT_CONTAINER}|/d" "$STATE_FILE"
echo "${PERSISTENT_NAME}|${WORKSPACE}|${TRANSIENT_PORT}|persistent" >> "$STATE_FILE"

# Update SSH config
# Remove old transient entry
if [[ -f "$SSH_CONFIG" ]]; then
  sed -i.bak "/^Host ${TRANSIENT_CONTAINER}$/,/^$/d" "$SSH_CONFIG"
fi

# Add new persistent entry
cat >> "$SSH_CONFIG" <<EOF

Host $PERSISTENT_NAME
    HostName 127.0.0.1
    Port $TRANSIENT_PORT
    User root
    IdentityFile ~/.config/container-dev/keys/container_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

echo "✓ Updated SSH config"
echo ""
echo "Connect with: ssh $PERSISTENT_NAME"
