#!/usr/bin/env bash
set -euo pipefail

# List all container-dev containers with status (running and stopped)

STATE_FILE="$HOME/.config/container-dev/state"
SSH_CONFIG="$HOME/.ssh/config"

echo "Container-dev Environments"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get all containers (running + stopped), with name and state
ALL_CONTAINERS=$(container list --all 2>/dev/null | awk 'NR>1{print $1, $5}' || true)

if [[ -z "$ALL_CONTAINERS" ]]; then
  ALL_CONTAINERS=""
fi

# Filter to only container-dev containers
FILTERED=""
while IFS=' ' read -r name state; do
  [[ -z "$name" ]] && continue
  if [[ "$name" =~ -transient$ ]] || [[ "$name" =~ ^(claude|opencode|pi)(-[a-z0-9]+)*-[a-z0-9]+$ ]]; then
    FILTERED="${FILTERED}${name} ${state}"$'\n'
  fi
done <<< "$ALL_CONTAINERS"

# Reconcile: clean up state/SSH entries for containers that no longer exist
if [[ -f "$STATE_FILE" ]]; then
  LIVE_NAMES=$(echo "$ALL_CONTAINERS" | awk '{print $1}')
  STALE_CLEANED=false
  while IFS='|' read -r sname sworkspace sport stype sprofile; do
    [[ -z "$sname" ]] && continue
    if ! echo "$LIVE_NAMES" | grep -qx "$sname"; then
      # Container no longer exists — clean up
      sed -i.bak "/^${sname}|/d" "$STATE_FILE" 2>/dev/null || true
      if [[ -f "$SSH_CONFIG" ]] && grep -q "^Host ${sname}$" "$SSH_CONFIG" 2>/dev/null; then
        sed -i.bak "/^Host ${sname}$/,/^$/d" "$SSH_CONFIG"
      fi
      STALE_CLEANED=true
    fi
  done < "$STATE_FILE"
  if [[ "$STALE_CLEANED" == true ]]; then
    echo "(Cleaned up stale entries for removed containers)"
    echo ""
  fi
fi

if [[ -z "$FILTERED" ]]; then
  echo "No container-dev containers found."
  echo ""
  echo "Create a container with:"
  echo "  container-dev create <profile>"
  exit 0
fi

# Separate transient and persistent
TRANSIENT=""
PERSISTENT=""

while IFS=' ' read -r name state; do
  [[ -z "$name" ]] && continue
  if [[ "$name" == *-transient ]]; then
    TRANSIENT="${TRANSIENT}${name} ${state}"$'\n'
  else
    PERSISTENT="${PERSISTENT}${name} ${state}"$'\n'
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
  echo "Transient Containers (auto-replaced on workspace change)"
  echo "───────────────────────────────────────────────────────────────────"
  while IFS=' ' read -r container_name container_state; do
    [[ -z "$container_name" ]] && continue

    STATE_INFO=$(get_state_info "$container_name")
    if [[ -n "$STATE_INFO" ]]; then
      WORKSPACE=$(echo "$STATE_INFO" | cut -d'|' -f2)
      PORT=$(echo "$STATE_INFO" | cut -d'|' -f3)
      PROFILE=$(echo "$STATE_INFO" | cut -d'|' -f5)
      [[ -z "$PROFILE" ]] && PROFILE="${container_name%-transient}"
      echo "  ssh $container_name  [$container_state]"
      echo "  code --remote ssh-remote+$container_name /workspace"
      echo "    Profile:   $PROFILE"
      echo "    Workspace: $WORKSPACE"
      echo "    Port:      $PORT"
      echo ""
    else
      echo "  $container_name  [$container_state]"
      echo "    (No state info)"
      echo ""
    fi
  done <<< "$TRANSIENT"
fi

# Display persistent containers
if [[ -n "$PERSISTENT" ]]; then
  echo "Persistent Containers (dedicated, never auto-replaced)"
  echo "───────────────────────────────────────────────────────────────────"
  while IFS=' ' read -r container_name container_state; do
    [[ -z "$container_name" ]] && continue

    STATE_INFO=$(get_state_info "$container_name")
    if [[ -n "$STATE_INFO" ]]; then
      WORKSPACE=$(echo "$STATE_INFO" | cut -d'|' -f2)
      PORT=$(echo "$STATE_INFO" | cut -d'|' -f3)
      PROFILE=$(echo "$STATE_INFO" | cut -d'|' -f5)
      [[ -z "$PROFILE" ]] && PROFILE=$(echo "$container_name" | sed 's/-[^-]*$//')
      echo "  ssh $container_name  [$container_state]"
      echo "  code --remote ssh-remote+$container_name /workspace"
      echo "    Profile:   $PROFILE"
      echo "    Workspace: $WORKSPACE"
      echo "    Port:      $PORT"
      echo ""
    else
      echo "  $container_name  [$container_state]"
      echo "    (No state info)"
      echo ""
    fi
  done <<< "$PERSISTENT"
fi

# Count totals
RUNNING_COUNT=$(echo "$FILTERED" | grep -c ' running' || echo 0)
TOTAL_COUNT=$(echo "$FILTERED" | grep -c '[^ ]' || echo 0)
STOPPED_COUNT=$((TOTAL_COUNT - RUNNING_COUNT))

TRANSIENT_COUNT=$(echo "$TRANSIENT" | grep -c '[^ ]' || echo 0)
PERSISTENT_COUNT=$(echo "$PERSISTENT" | grep -c '[^ ]' || echo 0)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $RUNNING_COUNT running, $STOPPED_COUNT stopped ($TRANSIENT_COUNT transient, $PERSISTENT_COUNT persistent)"
echo ""
echo "  Pause:   container stop <name>"
echo "  Resume:  container start <name>"
echo "  Delete:  container-dev delete <name>"
