#!/usr/bin/env bash
set -euo pipefail

# List all container-dev containers with status (running and stopped)

STATE_FILE="$HOME/.config/container-dev/state"
SSH_CONFIG="$HOME/.ssh/config"

echo "Container-dev Environments"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get all containers (running + stopped), with name and state.
#
# The exit status is checked separately, before piping into awk: under
# `set -o pipefail`, a failed `container list` would still look like success
# here because awk succeeds on empty input, making a dead/unready backend
# indistinguishable from "zero containers exist". That distinction matters
# because the reconciliation step below deletes state/SSH entries for any
# container it can't see — treating a failed call as "no containers" makes it
# wipe every persisted entry (e.g. right after a reboot, before the container
# runtime has finished starting).
if RAW_LIST=$(container list --all 2>&1); then
  LIST_STATUS=0
else
  LIST_STATUS=$?
fi

if [[ $LIST_STATUS -ne 0 ]]; then
  echo "ERROR: 'container list --all' failed (status $LIST_STATUS) — is the container runtime running?" >&2
  echo "$RAW_LIST" >&2
  echo "" >&2
  echo "Refusing to continue: reconciling state against an unreachable backend" >&2
  echo "would delete valid entries for containers that are actually still there." >&2
  echo "Run 'container system start' and try again." >&2
  exit 1
fi

ALL_CONTAINERS=$(echo "$RAW_LIST" | awk 'NR>1{print $1, $5}')

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
      if [[ "$WORKSPACE" == *,* ]]; then
        echo "    Workspaces:"
        IFS=',' read -ra WS_LIST <<< "$WORKSPACE"
        for ws in "${WS_LIST[@]}"; do
          echo "  code --remote ssh-remote+$container_name /workspace/$(basename "$ws")"
          echo "      /workspace/$(basename "$ws") → $ws"
        done
      else
        echo "  code --remote ssh-remote+$container_name /workspace/$(basename "$WORKSPACE")"
        echo "    Workspace: $WORKSPACE"
      fi
      echo "    Profile:   $PROFILE"
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
      if [[ "$WORKSPACE" == *,* ]]; then
        echo "    Workspaces:"
        IFS=',' read -ra WS_LIST <<< "$WORKSPACE"
        for ws in "${WS_LIST[@]}"; do
          echo "  code --remote ssh-remote+$container_name /workspace/$(basename "$ws")"
          echo "      /workspace/$(basename "$ws") → $ws"
        done
      else
        echo "  code --remote ssh-remote+$container_name /workspace/$(basename "$WORKSPACE")"
        echo "    Workspace: $WORKSPACE"
      fi
      echo "    Profile:   $PROFILE"
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
RUNNING_COUNT=$(echo "$FILTERED" | grep -c ' running' || true)
TOTAL_COUNT=$(echo "$FILTERED" | grep -c '[^ ]' || true)
STOPPED_COUNT=$((TOTAL_COUNT - RUNNING_COUNT))

TRANSIENT_COUNT=$(echo "$TRANSIENT" | grep -c '[^ ]' || true)
PERSISTENT_COUNT=$(echo "$PERSISTENT" | grep -c '[^ ]' || true)

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total: $RUNNING_COUNT running, $STOPPED_COUNT stopped ($TRANSIENT_COUNT transient, $PERSISTENT_COUNT persistent)"
echo ""
echo "  Pause:   container stop <name>"
echo "  Resume:  container start <name>"
echo "  Delete:  container-dev delete <name>"
