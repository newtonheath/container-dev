#!/usr/bin/env bash
#
# stop.sh — stop and remove a container-dev container
#
# Usage:
#   container-dev stop <container-name>
#   container-dev stop claude-transient
#   container-dev stop claude-importantproject
#
set -euo pipefail

STATE_FILE="$HOME/.config/container-dev/state"
SSH_CONFIG="$HOME/.ssh/config"

usage() {
  cat <<'EOF'
Usage: container-dev stop <container-name>

Arguments:
  container-name    Name of the container to stop (e.g., claude-transient, claude-myproject)

Examples:
  container-dev stop claude-transient
  container-dev stop opencode-local-research

To see all containers:
  container-dev list

EOF
  exit 0
}

if [[ $# -eq 0 ]]; then
  echo "ERROR: container name required" >&2
  echo "" >&2
  usage
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

CONTAINER_NAME="$1"

# Check if container exists
if ! container list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container '$CONTAINER_NAME' is not running."
  echo ""
  echo "Available containers:"
  container list 2>/dev/null | awk 'NR>1{print $1}' | grep -E -- '-(transient|[a-z0-9]+(-[a-z0-9]+)*)$' | sed 's/^/  /' || echo "  (none)"
  exit 1
fi

# Check if it's persistent (warn before stopping)
IS_PERSISTENT=false
if [[ -f "$STATE_FILE" ]]; then
  if grep -q "^${CONTAINER_NAME}|.*|persistent$" "$STATE_FILE"; then
    IS_PERSISTENT=true
  fi
fi

if [[ "$IS_PERSISTENT" == true ]]; then
  echo "⚠️  '$CONTAINER_NAME' is a persistent container"
  WORKSPACE=$(grep "^${CONTAINER_NAME}|" "$STATE_FILE" | cut -d'|' -f2)
  echo "   Workspace: $WORKSPACE"
  echo ""
  read -p "Stop and remove it? [y/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

# Stop and remove container
echo "Stopping $CONTAINER_NAME..."
container stop "$CONTAINER_NAME"
container rm "$CONTAINER_NAME"

# Remove from state file
if [[ -f "$STATE_FILE" ]]; then
  sed -i.bak "/^${CONTAINER_NAME}|/d" "$STATE_FILE"
fi

# Remove from SSH config
if [[ -f "$SSH_CONFIG" ]]; then
  if grep -q "^Host ${CONTAINER_NAME}$" "$SSH_CONFIG"; then
    echo "Removing SSH config entry..."
    sed -i.bak "/^Host ${CONTAINER_NAME}$/,/^$/d" "$SSH_CONFIG"
  fi
fi

echo "✓ Container stopped and removed"
