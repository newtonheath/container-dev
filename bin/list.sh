#!/usr/bin/env bash
set -euo pipefail

# List all container-dev containers with status

STATE_FILE="$HOME/.config/container-dev/state"

echo "Container-dev Environments"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get all running containers (skip header line)
RUNNING_CONTAINERS=$(container list 2>/dev/null | awk 'NR>1{print $1}' || true)

if [[ -z "$RUNNING_CONTAINERS" ]]; then
  echo "No containers running."
  echo ""
  echo "Start a container with:"
  echo "  container-dev start <profile>"
  exit 0
fi

# Filter to only container-dev containers (ending in -transient or with workspace slugs)
FILTERED=""
while IFS= read -r name; do
  if [[ "$name" =~ -transient$ ]] || [[ "$name" =~ ^(claude|opencode|pi)(-[a-z0-9]+)*-[a-z0-9]+$ ]]; then
    FILTERED="${FILTERED}${name}"$'\n'
  fi
done <<< "$RUNNING_CONTAINERS"

if [[ -z "$FILTERED" ]]; then
  echo "No container-dev containers running."
  echo ""
  echo "Start a container with:"
  echo "  container-dev start <profile>"
  exit 0
fi

# Separate transient and persistent
TRANSIENT=""
PERSISTENT=""

while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if [[ "$name" == *-transient ]]; then
    TRANSIENT="${TRANSIENT}${name}"$'\n'
  else
    PERSISTENT="${PERSISTENT}${name}"$'\n'
  fi
done <<< "$FILTERED"

# Helper to get state info
get_state_info() {
  local container_name="$1"
  if [[ -f "$STATE_FILE" ]]; then
    grep "^${container_name}|" "$STATE_FILE" 2>/dev/null || echo ""
  fi
}

# Display transient containers
if [[ -n "$TRANSIENT" ]]; then
  echo "📦 Transient Containers (auto-replaced on workspace change)"
  echo "───────────────────────────────────────────────────────────────────"
  while IFS= read -r container_name; do
    [[ -z "$container_name" ]] && continue

    STATE_INFO=$(get_state_info "$container_name")
    if [[ -n "$STATE_INFO" ]]; then
      WORKSPACE=$(echo "$STATE_INFO" | cut -d'|' -f2)
      PORT=$(echo "$STATE_INFO" | cut -d'|' -f3)
      PROFILE="${container_name%-transient}"
      echo "  ssh $container_name"
      echo "    Profile:   $PROFILE"
      echo "    Workspace: $WORKSPACE"
      echo "    Port:      $PORT"
      echo ""
    else
      echo "  ssh $container_name"
      echo "    (No state info)"
      echo ""
    fi
  done <<< "$TRANSIENT"
fi

# Display persistent containers
if [[ -n "$PERSISTENT" ]]; then
  echo "🔒 Persistent Containers (dedicated, never auto-replaced)"
  echo "───────────────────────────────────────────────────────────────────"
  while IFS= read -r container_name; do
    [[ -z "$container_name" ]] && continue

    STATE_INFO=$(get_state_info "$container_name")
    if [[ -n "$STATE_INFO" ]]; then
      WORKSPACE=$(echo "$STATE_INFO" | cut -d'|' -f2)
      PORT=$(echo "$STATE_INFO" | cut -d'|' -f3)
      # Extract profile (everything up to last hyphen + slug)
      PROFILE=$(echo "$container_name" | sed 's/-[^-]*$//')
      echo "  ssh $container_name"
      echo "    Profile:   $PROFILE"
      echo "    Workspace: $WORKSPACE"
      echo "    Port:      $PORT"
      echo ""
    else
      echo "  ssh $container_name"
      echo "    (No state info)"
      echo ""
    fi
  done <<< "$PERSISTENT"
fi

# Count totals
TRANSIENT_COUNT=$(echo "$TRANSIENT" | grep -c . || echo 0)
PERSISTENT_COUNT=$(echo "$PERSISTENT" | grep -c . || echo 0)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $TRANSIENT_COUNT transient, $PERSISTENT_COUNT persistent"
