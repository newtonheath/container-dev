#!/usr/bin/env bash
#
# run-fedora.sh — build (if needed) and run the Fedora dev container
# with an EXPLICIT memory and CPU allocation, plus a shared workspace.
#
# Usage:
#   ./run-fedora.sh                 # defaults below
#   MEM=16g CPUS=6 ./run-fedora.sh  # override per-invocation
#
set -euo pipefail

# --- knobs you care about ----------------------------------------------
IMAGE="fedora-dev"
NAME="fedora-dev"
MEM="${MEM:-4g}"                         # <-- memory cap. NOT half-of-host.
CPUS="${CPUS:-4}"                        # <-- CPU cores
HOST_DIR="${HOST_DIR:-$HOME/container-workspace}"
GUEST_DIR="/workspace"

# Resolve the directory THIS script lives in (so it works from anywhere).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find the Dockerfile whether it's named `Dockerfile` or `Dockerfile.fedora`.
if   [ -f "$SCRIPT_DIR/Dockerfile" ];        then DOCKERFILE="$SCRIPT_DIR/Dockerfile"
elif [ -f "$SCRIPT_DIR/Dockerfile.fedora" ]; then DOCKERFILE="$SCRIPT_DIR/Dockerfile.fedora"
else
  echo "ERROR: no Dockerfile or Dockerfile.fedora found in $SCRIPT_DIR" >&2
  exit 1
fi

mkdir -p "$HOST_DIR"

# Build only if the image isn't already present.
# The images plugin can be flaky; if the check errors we just build.
if container images list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$IMAGE"; then
  echo ">> Image '$IMAGE' already exists, skipping build."
else
  echo ">> Building $IMAGE from $DOCKERFILE ..."
  container build -t "$IMAGE" --file "$DOCKERFILE" "$SCRIPT_DIR"
fi

echo ">> Starting $NAME  (mem=$MEM cpus=$CPUS)"
echo ">> Sharing $HOST_DIR  ->  $GUEST_DIR"
exec container run \
  --rm --interactive --tty \
  --name "$NAME" \
  --memory "$MEM" \
  --cpus "$CPUS" \
  --volume "${HOST_DIR}:${GUEST_DIR}" \
  "$IMAGE" \
  /bin/bash
