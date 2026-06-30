#!/usr/bin/env bash
#
# start.sh — launch a container-dev environment (transient or persistent)
#
# Usage:
#   container-dev start <profile> [--persistent] [options]
#
set -euo pipefail

# ---------------------------------------------------------------------------
# paths and config
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_DIR="$HOME/.config/container-dev"
KEYS_DIR="$CONFIG_DIR/keys"
STATE_FILE="$CONFIG_DIR/state"
CONFIG_FILE="$CONFIG_DIR/config"

# ---------------------------------------------------------------------------
# per-profile base port map
# ---------------------------------------------------------------------------
profile_port() {
  case "$1" in
    claude)          echo 2222 ;;
    opencode)        echo 2230 ;;
    opencode-local)  echo 2231 ;;
    pi)              echo 2240 ;;
    pi-local)        echo 2241 ;;
    # Legacy profiles (deprecated)
    claude-vertex)   echo 2222 ;;
    claude-pro-api)  echo 2223 ;;
    claude-pro-web)  echo 2224 ;;
    *)               echo 2299 ;;
  esac
}

# ---------------------------------------------------------------------------
# detect Claude authentication method
# ---------------------------------------------------------------------------
detect_claude_auth() {
  # Check for override in config
  if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
    if [[ -n "${FORCE_CLAUDE_AUTH:-}" ]]; then
      echo "$FORCE_CLAUDE_AUTH"
      return
    fi
    if [[ -n "${CLAUDE_AUTH_TYPE:-}" ]]; then
      echo "$CLAUDE_AUTH_TYPE"
      return
    fi
  fi

  # Auto-detect
  if [[ -f "$HOME/.config/gcloud/application_default_credentials.json" ]]; then
    echo "vertex"
  elif [[ -n "${ANTHROPIC_API_KEY:-}" ]] || grep -q "ANTHROPIC_API_KEY" "${PROFILE_DIR}/.env" 2>/dev/null; then
    echo "api"
  else
    echo "web"
  fi
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: container-dev start <profile> [--persistent] [options]

Arguments:
  profile     Profile name: claude, opencode, opencode-local, pi, pi-local

Flags:
  --persistent         Create dedicated container for this workspace (never auto-replaced)
                       Default: transient (auto-replaced when switching workspaces)

Options:
  --size <small|medium|large>   Resource preset (default: medium)
  --cpus <n>                    CPU cores (overrides --size)
  --mem  <size>                 Memory limit, e.g. 4g (overrides --size)
  --port <port>                 Host SSH port (default: auto-assigned)
  -h, --help                    Show this help

Examples:
  # Transient container (auto-replaced on workspace change)
  cd ~/experiments/test
  container-dev start claude
  ssh claude-transient

  # Persistent container (dedicated, never auto-replaced)
  cd ~/work/important-project
  container-dev start claude --persistent
  ssh claude-importantproject

EOF
  exit 0
}

# ---------------------------------------------------------------------------
# parse arguments
# ---------------------------------------------------------------------------
PROFILE=""
PERSISTENT=false
SIZE=""
CPUS=""
MEM=""
SSH_PORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        usage ;;
    --persistent|-p)  PERSISTENT=true; shift ;;
    --size)           SIZE="$2"; shift 2 ;;
    --cpus)           CPUS="$2"; shift 2 ;;
    --mem)            MEM="$2"; shift 2 ;;
    --port)           SSH_PORT="$2"; shift 2 ;;
    -*)
      echo "ERROR: unknown option '$1'" >&2
      usage
      ;;
    *)
      if [[ -z "$PROFILE" ]]; then
        PROFILE="$1"
      else
        echo "ERROR: unexpected argument '$1'" >&2
        usage
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROFILE" ]]; then
  echo "ERROR: profile is required" >&2
  usage
fi

# ---------------------------------------------------------------------------
# workspace detection
# ---------------------------------------------------------------------------
WORKSPACE="$(pwd)"
WORKSPACE_SLUG=$(basename "$WORKSPACE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')

# ---------------------------------------------------------------------------
# container naming
# ---------------------------------------------------------------------------
if [[ "$PERSISTENT" == true ]]; then
  CONTAINER_NAME="${PROFILE}-${WORKSPACE_SLUG}"
  CONTAINER_TYPE="persistent"
else
  CONTAINER_NAME="${PROFILE}-transient"
  CONTAINER_TYPE="transient"
fi

IMAGE_NAME="${PROFILE}-img"

# ---------------------------------------------------------------------------
# validate profile
# ---------------------------------------------------------------------------
PROFILE_DIR="$PROJECT_DIR/profiles/$PROFILE"
if [[ ! -d "$PROFILE_DIR" ]]; then
  echo "ERROR: profile directory not found: $PROFILE_DIR" >&2
  echo "" >&2
  echo "Available profiles:" >&2
  ls -1 "$PROJECT_DIR/profiles" | grep -v '^_' | sed 's/^/  /' >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# check for existing container
# ---------------------------------------------------------------------------
if container list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$CONTAINER_NAME"; then
  # Container already running - check if workspace matches (for transient)
  if [[ "$PERSISTENT" == false ]]; then
    EXISTING_WORKSPACE=$(grep "^${CONTAINER_NAME}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f2 || echo "")
    if [[ "$EXISTING_WORKSPACE" == "$WORKSPACE" ]]; then
      echo "✓ Container '$CONTAINER_NAME' already running with this workspace"
      echo ""
      echo "  SSH:    ssh $CONTAINER_NAME"
      echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace"
      exit 0
    else
      echo "Switching transient workspace:"
      echo "  From: $EXISTING_WORKSPACE"
      echo "  To:   $WORKSPACE"
      echo ""
      echo "Stopping old transient container..."
      container stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
      container rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
      sed -i.bak "/^${CONTAINER_NAME}|/d" "$STATE_FILE" 2>/dev/null || true
    fi
  else
    echo "✓ Persistent container '$CONTAINER_NAME' already running"
    echo ""
    echo "  SSH:    ssh $CONTAINER_NAME"
    echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace"
    exit 0
  fi
fi

# Clean up any stopped container with the same name
container rm "$CONTAINER_NAME" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# detect auth for Claude-based profiles
# ---------------------------------------------------------------------------
CLAUDE_AUTH_TYPE="none"
if [[ "$PROFILE" =~ ^(claude|opencode|pi)$ ]]; then
  CLAUDE_AUTH_TYPE=$(detect_claude_auth)

  # Save detected auth to config file
  mkdir -p "$CONFIG_DIR"
  if ! grep -q "CLAUDE_AUTH_TYPE=" "$CONFIG_FILE" 2>/dev/null; then
    echo "CLAUDE_AUTH_TYPE=$CLAUDE_AUTH_TYPE" >> "$CONFIG_FILE"
    echo "Detected Claude auth: $CLAUDE_AUTH_TYPE (saved to config)"
  fi
fi

# ---------------------------------------------------------------------------
# resource limits
# ---------------------------------------------------------------------------
if [[ -n "$SIZE" ]]; then
  case "$SIZE" in
    small)  CPUS=2; MEM="2g" ;;
    medium) CPUS=4; MEM="4g" ;;
    large)  CPUS=6; MEM="8g" ;;
    *)
      echo "ERROR: unknown size '$SIZE' (small|medium|large)" >&2
      exit 1
      ;;
  esac
fi
CPUS="${CPUS:-4}"
MEM="${MEM:-4g}"

# ---------------------------------------------------------------------------
# port assignment
# ---------------------------------------------------------------------------
if [[ -z "$SSH_PORT" ]]; then
  BASE_PORT=$(profile_port "$PROFILE")
  SSH_PORT=$BASE_PORT
  # Find next available port if base is taken
  while lsof -i ":$SSH_PORT" >/dev/null 2>&1; do
    ((SSH_PORT++))
  done
  if [[ "$SSH_PORT" != "$BASE_PORT" ]]; then
    echo "Note: Port $BASE_PORT in use, using $SSH_PORT instead"
  fi
fi

# ---------------------------------------------------------------------------
# SSH keypair
# ---------------------------------------------------------------------------
mkdir -p "$KEYS_DIR"
KEY_FILE="$KEYS_DIR/container_ed25519"
if [[ ! -f "$KEY_FILE" ]]; then
  echo ">> Generating SSH keypair..."
  ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "container-dev"
fi

# ---------------------------------------------------------------------------
# env file (profile-specific, optional)
# ---------------------------------------------------------------------------
ENV_FILE="$PROFILE_DIR/.env"
USER_ENV_FILE="$CONFIG_DIR/env"
ENV_FILE_ARGS=()

# Helper function to read env file and convert to -e flags
load_env_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Skip empty lines and comments
      [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

      # Trim whitespace
      line=$(echo "$line" | xargs)

      # Check if line contains '=' (KEY=VALUE format)
      if [[ "$line" =~ = ]]; then
        # Direct KEY=VALUE, pass as-is
        ENV_FILE_ARGS+=("-e" "$line")
      else
        # Just a variable name, expand from host environment
        local varname="$line"
        local varvalue="${!varname:-}"
        if [[ -n "$varvalue" ]]; then
          ENV_FILE_ARGS+=("-e" "${varname}=${varvalue}")
        else
          echo "   WARN: $varname not set in environment, skipping"
        fi
      fi
    done < "$file"
  fi
}

# Load user-level env file first (personal settings)
load_env_file "$USER_ENV_FILE"

# Load profile-level env file second (can override user settings)
load_env_file "$ENV_FILE"

# ---------------------------------------------------------------------------
# volume mounts
# ---------------------------------------------------------------------------
MOUNT_ARGS=(
  --volume "${WORKSPACE}:/workspace"
  --volume "${KEY_FILE}.pub:/tmp/pubkey/authorized_keys:ro"
)

# Auth-specific mounts (Claude-based profiles)
if [[ "$PROFILE" =~ ^(claude|opencode|pi)$ ]]; then
  case "$CLAUDE_AUTH_TYPE" in
    vertex)
      ADC_PATH="$HOME/.config/gcloud/application_default_credentials.json"
      if [[ -f "$ADC_PATH" ]]; then
        MOUNT_ARGS+=(--volume "${ADC_PATH}:/root/.config/gcloud/application_default_credentials.json:ro")
      else
        echo "WARN: Vertex auth detected but gcloud ADC not found" >&2
        echo "  Run 'gcloud auth application-default login' to set up credentials" >&2
      fi
      ;;
    web)
      AUTH_DIR="$CONFIG_DIR/auth/claude"
      mkdir -p "$AUTH_DIR"
      MOUNT_ARGS+=(--volume "${AUTH_DIR}:/root/.claude")
      ;;
  esac
fi

# Model mounts (local profiles)
if [[ "$PROFILE" =~ -local$ ]]; then
  MODEL_DIR="$CONFIG_DIR/models"
  mkdir -p "$MODEL_DIR"
  MOUNT_ARGS+=(--volume "${MODEL_DIR}:/root/.cache/models:ro")
fi

# ---------------------------------------------------------------------------
# environment variables passed to container
# ---------------------------------------------------------------------------
CONTAINER_ENV=(
  -e "WORKSPACE_PATH=$WORKSPACE"
  -e "CONTAINER_NAME=$CONTAINER_NAME"
  -e "CLAUDE_AUTH_TYPE=$CLAUDE_AUTH_TYPE"
)

# Auth-specific env vars
if [[ "$PROFILE" =~ ^(claude|opencode|pi)$ ]]; then
  case "$CLAUDE_AUTH_TYPE" in
    vertex)
      CONTAINER_ENV+=(-e "ANTHROPIC_VERTEX_PROJECT_ID=${ANTHROPIC_VERTEX_PROJECT_ID:-}")
      CONTAINER_ENV+=(-e "CLOUD_ML_REGION=${CLOUD_ML_REGION:-us-central1}")
      ;;
    api)
      CONTAINER_ENV+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}")
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# find Dockerfile
# ---------------------------------------------------------------------------
if [[ -f "$PROFILE_DIR/Dockerfile" ]]; then
  DOCKERFILE="$PROFILE_DIR/Dockerfile"
elif [[ -f "$PROFILE_DIR/Containerfile" ]]; then
  DOCKERFILE="$PROFILE_DIR/Containerfile"
else
  echo "ERROR: no Dockerfile found in $PROFILE_DIR" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# build image if needed
# ---------------------------------------------------------------------------
if container image list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$IMAGE_NAME"; then
  echo ">> Image '$IMAGE_NAME' exists"
else
  echo ">> Building $IMAGE_NAME from $DOCKERFILE ..."
  container build -t "$IMAGE_NAME" --file "$DOCKERFILE" "$PROFILE_DIR"
fi

# ---------------------------------------------------------------------------
# launch container
# ---------------------------------------------------------------------------
echo ">> Starting $CONTAINER_NAME ($CONTAINER_TYPE)"
echo "   Workspace: $WORKSPACE"
echo "   Profile:   $PROFILE"
echo "   Resources: cpus=$CPUS mem=$MEM"
echo "   SSH port:  $SSH_PORT"
if [[ "$CLAUDE_AUTH_TYPE" != "none" ]]; then
  echo "   Auth:      Claude ($CLAUDE_AUTH_TYPE)"
fi
echo ""

container run --detach \
  --name "$CONTAINER_NAME" \
  --cpus "$CPUS" \
  --memory "$MEM" \
  --publish "${SSH_PORT}:22" \
  ${MOUNT_ARGS[@]+"${MOUNT_ARGS[@]}"} \
  ${CONTAINER_ENV[@]+"${CONTAINER_ENV[@]}"} \
  ${ENV_FILE_ARGS[@]+"${ENV_FILE_ARGS[@]}"} \
  "$IMAGE_NAME"

# ---------------------------------------------------------------------------
# record state
# ---------------------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
sed -i.bak "/^${CONTAINER_NAME}|/d" "$STATE_FILE" 2>/dev/null || true
echo "${CONTAINER_NAME}|${WORKSPACE}|${SSH_PORT}|${CONTAINER_TYPE}" >> "$STATE_FILE"

# ---------------------------------------------------------------------------
# update SSH config
# ---------------------------------------------------------------------------
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"

# Remove existing entry if present
if grep -q "^Host ${CONTAINER_NAME}$" "$SSH_CONFIG" 2>/dev/null; then
  # Remove from "Host" line to next empty line
  sed -i.bak "/^Host ${CONTAINER_NAME}$/,/^$/d" "$SSH_CONFIG"
fi

# Add new entry
cat >> "$SSH_CONFIG" <<EOF

Host $CONTAINER_NAME
    HostName 127.0.0.1
    Port $SSH_PORT
    User root
    IdentityFile $KEY_FILE
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF

# ---------------------------------------------------------------------------
# done
# ---------------------------------------------------------------------------
echo "✓ Container ready"
echo ""
echo "  SSH:    ssh $CONTAINER_NAME"
echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace"
echo ""
if [[ "$PERSISTENT" == false ]]; then
  echo "  Type:   Transient (will auto-replace when switching workspaces)"
  echo "  Persist: container-dev persist  (convert to persistent)"
else
  echo "  Type:   Persistent (dedicated, never auto-replaced)"
fi
echo ""
echo "  List:   container-dev list"
echo "  Stop:   container-dev stop $CONTAINER_NAME"
