#!/usr/bin/env bash
#
# stop.sh — stop and remove a profile-based dev container
#
# Usage:
#   ./bin/stop.sh claude-vertex    # stop the claude-vertex-container
#   ./bin/stop.sh                  # stop all *-container containers from this project
#
set -euo pipefail

stop_container() {
  local name="$1"
  if container list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$name"; then
    echo ">> Stopping $name ..."
    container stop "$name"
    container delete "$name"
    echo ">> Removed $name."
  else
    echo ">> Container '$name' is not running."
  fi
}

if [[ $# -ge 1 ]]; then
  stop_container "${1}-container"
else
  echo ">> Stopping all dev containers..."
  for name in $(container list 2>/dev/null | awk 'NR>1{print $1}' | grep -- '-container$'); do
    stop_container "$name"
  done
fi
