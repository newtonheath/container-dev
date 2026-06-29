#!/usr/bin/env bash
#
# start.sh — build (if needed) and launch a profile-based dev container
#
# Usage:
#   ./bin/start.sh <profile> <workspace>  [options]
#   ./bin/start.sh claude-vertex ~/repos/myapp
#   ./bin/start.sh claude-vertex ~/repos/myapp --size large
#   ./bin/start.sh claude-vertex ~/repos/myapp --cpus 6 --mem 8g
#
set -euo pipefail

# ---------------------------------------------------------------------------
# resolve project root (one level up from bin/)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
KEYS_DIR="$HOME/.config/container-dev/keys"

# ---------------------------------------------------------------------------
# per-profile port map
# ---------------------------------------------------------------------------
profile_port() {
  case "$1" in
    claude-vertex)  echo 2222 ;;
    claude-pro-api) echo 2223 ;;
    claude-pro-web) echo 2224 ;;
    *)              echo 2225 ;;
  esac
}

# ---------------------------------------------------------------------------
# size presets  (8-CPU / 16GB host)
# ---------------------------------------------------------------------------
apply_size() {
  case "$1" in
    small)  CPUS=2; MEM="2g" ;;
    medium) CPUS=4; MEM="4g" ;;
    large)  CPUS=6; MEM="8g" ;;
    *)
      echo "ERROR: unknown size '$1' (small|medium|large)" >&2
      exit 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: start.sh <profile> <workspace> [options]

Arguments:
  profile     Profile name (directory under profiles/)
  workspace   Path to the host directory to mount as /workspace

Options:
  --size <small|medium|large>   Resource preset (default: medium)
  --cpus <n>                    CPU cores (overrides --size)
  --mem  <size>                 Memory limit, e.g. 4g (overrides --size)
  --port <port>                 Host SSH port (default: per-profile)
  -h, --help                    Show this help
EOF
  exit 0
}

# ---------------------------------------------------------------------------
# parse arguments
# ---------------------------------------------------------------------------
PROFILE=""
WORKSPACE=""
SIZE=""
CPUS=""
MEM=""
SSH_PORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)  usage ;;
    --size)     SIZE="$2";     shift 2 ;;
    --cpus)     CPUS="$2";     shift 2 ;;
    --mem)      MEM="$2";      shift 2 ;;
    --port)     SSH_PORT="$2"; shift 2 ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      usage
      ;;
    *)
      if   [[ -z "$PROFILE" ]];   then PROFILE="$1"
      elif [[ -z "$WORKSPACE" ]]; then WORKSPACE="$1"
      else echo "ERROR: unexpected argument '$1'" >&2; usage
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROFILE" || -z "$WORKSPACE" ]]; then
  echo "ERROR: profile and workspace are required" >&2
  usage
fi

# ---------------------------------------------------------------------------
# resolve paths and defaults
# ---------------------------------------------------------------------------
PROFILE_DIR="$PROJECT_DIR/profiles/$PROFILE"
if [[ ! -d "$PROFILE_DIR" ]]; then
  echo "ERROR: profile directory not found: $PROFILE_DIR" >&2
  exit 1
fi

WORKSPACE="$(cd "$WORKSPACE" 2>/dev/null && pwd || echo "$WORKSPACE")"
if [[ ! -d "$WORKSPACE" ]]; then
  echo "ERROR: workspace directory not found: $WORKSPACE" >&2
  exit 1
fi

CONTAINER_NAME="${PROFILE}-container"
IMAGE_NAME="${PROFILE}-img"
SSH_PORT="${SSH_PORT:-$(profile_port "$PROFILE")}"

# apply size preset, then let explicit --cpus/--mem override
if [[ -n "$SIZE" ]]; then
  apply_size "$SIZE"
fi
CPUS="${CPUS:-4}"
MEM="${MEM:-4g}"

# ---------------------------------------------------------------------------
# find Dockerfile
# ---------------------------------------------------------------------------
if   [[ -f "$PROFILE_DIR/Dockerfile" ]];        then DOCKERFILE="$PROFILE_DIR/Dockerfile"
elif [[ -f "$PROFILE_DIR/Containerfile" ]];      then DOCKERFILE="$PROFILE_DIR/Containerfile"
else
  echo "ERROR: no Dockerfile found in $PROFILE_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# env file (optional — used if present, skipped if absent)
# ---------------------------------------------------------------------------
ENV_FILE="$PROFILE_DIR/.env"
ENV_FILE_ARGS=()
if [[ -f "$ENV_FILE" ]]; then
  ENV_FILE_ARGS=(--env-file "$ENV_FILE")
fi

# ---------------------------------------------------------------------------
# SSH keypair (dedicated — never uses host personal keys)
# ---------------------------------------------------------------------------
mkdir -p "$KEYS_DIR"
KEY_FILE="$KEYS_DIR/container_ed25519"
if [[ ! -f "$KEY_FILE" ]]; then
  echo ">> Generating dedicated SSH keypair for container access..."
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "container-dev"
fi

# ---------------------------------------------------------------------------
# persistent ~/.claude auth volume (only for browser-auth profiles)
# ---------------------------------------------------------------------------
AUTH_MOUNT_ARGS=()
if [[ "$PROFILE" == "claude-pro-web" ]]; then
  AUTH_DIR="$HOME/.config/container-dev/auth/${PROFILE}"
  mkdir -p "$AUTH_DIR"
  AUTH_MOUNT_ARGS=(--volume "${AUTH_DIR}:/root/.claude")
fi

# ---------------------------------------------------------------------------
# gcloud ADC credentials (only for Vertex AI profiles)
# ---------------------------------------------------------------------------
ADC_MOUNT_ARGS=()
if grep -q 'CLAUDE_CODE_USE_VERTEX' "$ENV_FILE" 2>/dev/null; then
  ADC_FILE="$HOME/.config/gcloud/application_default_credentials.json"
  if [[ -f "$ADC_FILE" ]]; then
    ADC_MOUNT_ARGS=(--volume "${ADC_FILE}:/root/.config/gcloud/application_default_credentials.json:ro")
  else
    echo "WARN: gcloud ADC not found at $ADC_FILE" >&2
    echo "  Run 'gcloud auth application-default login' on the host to set up credentials." >&2
  fi
fi

# ---------------------------------------------------------------------------
# check if container is already running
# ---------------------------------------------------------------------------
if container list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CONTAINER_NAME"; then
  echo ">> Container '$CONTAINER_NAME' is already running."
  echo ""
  echo "  SSH:    ssh ${PROFILE}-host"
  echo "  VSCode: code --remote ssh-remote+${PROFILE}-host /workspace"
  echo ""
  echo "  Stop:   ./bin/stop.sh $PROFILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# build image if needed
# ---------------------------------------------------------------------------
if container image list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$IMAGE_NAME"; then
  echo ">> Image '$IMAGE_NAME' already exists, skipping build."
else
  echo ">> Building $IMAGE_NAME from $DOCKERFILE ..."
  container build -t "$IMAGE_NAME" --file "$DOCKERFILE" "$PROFILE_DIR"
fi

# ---------------------------------------------------------------------------
# launch container
# ---------------------------------------------------------------------------
echo ">> Starting $CONTAINER_NAME (cpus=$CPUS mem=$MEM port=$SSH_PORT)"
echo ">> Workspace: $WORKSPACE -> /workspace"

container run --detach \
  --name "$CONTAINER_NAME" \
  --cpus "$CPUS" \
  --memory "$MEM" \
  --publish "${SSH_PORT}:22" \
  --volume "${WORKSPACE}:/workspace" \
  --volume "${KEY_FILE}.pub:/tmp/pubkey/authorized_keys:ro" \
  ${AUTH_MOUNT_ARGS[@]+"${AUTH_MOUNT_ARGS[@]}"} \
  ${ADC_MOUNT_ARGS[@]+"${ADC_MOUNT_ARGS[@]}"} \
  ${ENV_FILE_ARGS[@]+"${ENV_FILE_ARGS[@]}"} \
  "$IMAGE_NAME"

# ---------------------------------------------------------------------------
# auto-configure ~/.ssh/config
# ---------------------------------------------------------------------------
SSH_HOST="${PROFILE}-host"
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"

if ! grep -q "^Host ${SSH_HOST}$" "$SSH_CONFIG" 2>/dev/null; then
  echo ">> Adding '$SSH_HOST' to $SSH_CONFIG"
  cat >> "$SSH_CONFIG" <<EOF

Host ${SSH_HOST}
    HostName localhost
    Port ${SSH_PORT}
    User root
    IdentityFile ${KEY_FILE}
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
fi

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
echo ""
echo ">> Container '$CONTAINER_NAME' is running."
echo ""
echo "  SSH:    ssh ${SSH_HOST}"
echo "  VSCode: code --remote ssh-remote+${SSH_HOST} /workspace"
echo ""
echo "  Stop:   ./bin/stop.sh $PROFILE"
