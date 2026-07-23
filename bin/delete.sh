#!/usr/bin/env bash
#
# delete.sh — permanently remove a container-dev container
#
# Usage:
#   container-dev delete <container-name>
#
set -euo pipefail

STATE_FILE="$HOME/.config/container-dev/state"
SSH_CONFIG="$HOME/.ssh/config"

usage() {
  cat <<'EOF'
Usage: container-dev delete <container-name>

Permanently removes a container and cleans up its SSH config and state.
Use 'container stop' to pause a container without removing it.

Arguments:
  container-name    Name of the container to delete (e.g., claude-transient, claude-myproject)

Examples:
  container-dev delete claude-transient
  container-dev delete opencode-local-research

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

# Check if container exists (running or stopped)
CONTAINER_STATE=$(container list --all 2>/dev/null | awk -v n="$CONTAINER_NAME" 'NR>1 && $1==n {print $5}')

if [[ -z "$CONTAINER_STATE" ]]; then
  echo "Container '$CONTAINER_NAME' not found."
  echo ""
  echo "Available containers:"
  container list --all 2>/dev/null | awk 'NR>1{print $1}' | grep -E -- '-(transient|[a-z0-9]+(-[a-z0-9]+)*)$' | sed 's/^/  /' || echo "  (none)"
  exit 1
fi

# Check if it's persistent (warn before deleting)
IS_PERSISTENT=false
if [[ -f "$STATE_FILE" ]]; then
  if grep "^${CONTAINER_NAME}|" "$STATE_FILE" | cut -d'|' -f4 | grep -qx "persistent" 2>/dev/null; then
    IS_PERSISTENT=true
  fi
fi

if [[ "$IS_PERSISTENT" == true ]]; then
  WORKSPACE=$(grep "^${CONTAINER_NAME}|" "$STATE_FILE" | cut -d'|' -f2)
  echo "Warning: '$CONTAINER_NAME' is a persistent container"
  echo "  Workspace: $WORKSPACE"
  echo ""
  read -p "Permanently delete it? [y/N] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
  fi
fi

# Stop if running, then remove
echo "Deleting $CONTAINER_NAME..."
if [[ "$CONTAINER_STATE" == "running" ]]; then
  container stop "$CONTAINER_NAME"
fi
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

echo "✓ Container deleted"
