#!/usr/bin/env bash
#
# create.sh — create (or resume) a container-dev environment
#
# Usage:
#   container-dev create <profile> [--persistent] [options]
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
# ensure SSH config entry exists (restores it if cleaned up)
# ---------------------------------------------------------------------------
ensure_ssh_config() {
  local name="$1"
  local port
  port=$(grep "^${name}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f3 || echo "")
  [[ -z "$port" ]] && return
  local key_file="$KEYS_DIR/container_ed25519"
  local ssh_config="$HOME/.ssh/config"
  if ! grep -q "^Host ${name}$" "$ssh_config" 2>/dev/null; then
    mkdir -p "$HOME/.ssh"
    cat >> "$ssh_config" <<SSHEOF

Host $name
    HostName 127.0.0.1
    Port $port
    User root
    IdentityFile $key_file
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
SSHEOF
    echo "  (SSH config entry restored)"
  fi
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
Usage: container-dev create <profile> [dirs...] [--persistent] [options]

Creates a new container or resumes a stopped one.

Arguments:
  profile     Profile name: claude, opencode, opencode-local, pi, pi-local
  dirs        Optional directories to mount (default: current directory)
              Each is mounted as /workspace/<dirname> in the container

Flags:
  --persistent         Create dedicated container for this workspace (never auto-replaced)
                       Default: transient (auto-replaced when switching workspaces)

Options:
  --name <slug>                 Container name suffix (auto-derived from workspace directory names
                                if not provided)
  --size <small|medium|large>   Resource preset (default: medium)
  --cpus <n>                    CPU cores (overrides --size)
  --mem  <size>                 Memory limit, e.g. 4g (overrides --size)
  --port <port>                 Host SSH port (default: auto-assigned)
  -h, --help                    Show this help

Examples:
  # Single workspace (mounts current directory as /workspace)
  cd ~/experiments/test
  container-dev create claude
  ssh claude-transient

  # Multiple workspaces (each mounted under /workspace/<name>)
  container-dev create claude ~/projects/scraps ~/projects/relval
  # Mounts: /workspace/scraps, /workspace/relval

  # Persistent container with multiple workspaces
  container-dev create claude ~/work/svc ~/work/fleet --persistent --name my-stack
  ssh claude-my-stack

  # Persistent container (single workspace, name auto-derived)
  cd ~/work/important-project
  container-dev create claude --persistent
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
CUSTOM_NAME=""
WORKSPACES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        usage ;;
    --persistent|-p)  PERSISTENT=true; shift ;;
    --name)           CUSTOM_NAME="$2"; shift 2 ;;
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
        WORKSPACES+=("$1")
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
MULTI_WORKSPACE=false

if [[ ${#WORKSPACES[@]} -gt 0 ]]; then
  MULTI_WORKSPACE=true
  # Validate and resolve to absolute paths
  for i in "${!WORKSPACES[@]}"; do
    ws="${WORKSPACES[$i]}"
    if [[ ! -d "$ws" ]]; then
      echo "ERROR: directory not found: $ws" >&2
      exit 1
    fi
    WORKSPACES[$i]=$(cd "$ws" && pwd)
  done
  # Sort for consistent state comparison
  IFS=$'\n' WORKSPACES=($(sort <<<"${WORKSPACES[*]}")); unset IFS
  # WORKSPACE stores comma-separated paths for state file
  WORKSPACE=$(IFS=,; echo "${WORKSPACES[*]}")
else
  WORKSPACE="$(pwd)"
fi

# ---------------------------------------------------------------------------
# container naming
# ---------------------------------------------------------------------------
if [[ "$PERSISTENT" == true ]]; then
  if [[ -n "$CUSTOM_NAME" ]]; then
    WORKSPACE_SLUG=$(echo "$CUSTOM_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
  elif [[ "$MULTI_WORKSPACE" == true ]]; then
    # Auto-derive name from workspace basenames joined with '-'
    AUTO_NAME=$(printf '%s\n' "${WORKSPACES[@]}" | xargs -I{} basename {} | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9\n-' | paste -sd'-')
    WORKSPACE_SLUG="$AUTO_NAME"
  else
    WORKSPACE_SLUG=$(basename "$WORKSPACE" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
  fi
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
# check for existing container (running or stopped)
# ---------------------------------------------------------------------------
CONTAINER_STATE=$(container list --all 2>/dev/null | awk -v n="$CONTAINER_NAME" 'NR>1 && $1==n {print $5}')

if [[ "$CONTAINER_STATE" == "running" ]]; then
  if [[ "$PERSISTENT" == false ]]; then
    EXISTING_WORKSPACE=$(grep "^${CONTAINER_NAME}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f2 || echo "")
    if [[ "$EXISTING_WORKSPACE" == "$WORKSPACE" ]]; then
      ensure_ssh_config "$CONTAINER_NAME"
      echo "✓ Container '$CONTAINER_NAME' already running with this workspace"
      echo ""
      echo "  SSH:    ssh $CONTAINER_NAME"
      if [[ "$MULTI_WORKSPACE" == true ]]; then
        for ws in "${WORKSPACES[@]}"; do
          echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace/$(basename "$ws")"
        done
      else
        echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace/$(basename "$WORKSPACE")"
      fi
      exit 0
    else
      echo "Switching transient workspace:"
      echo "  From: $EXISTING_WORKSPACE"
      echo "  To:   $WORKSPACE"
      echo ""
      echo "Replacing transient container..."
      container stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
      container rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
      sed -i.bak "/^${CONTAINER_NAME}|/d" "$STATE_FILE" 2>/dev/null || true
    fi
  else
    ensure_ssh_config "$CONTAINER_NAME"
    echo "✓ Persistent container '$CONTAINER_NAME' already running"
    echo ""
    echo "  SSH:    ssh $CONTAINER_NAME"
    if [[ "$MULTI_WORKSPACE" == true ]]; then
      for ws in "${WORKSPACES[@]}"; do
        echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace/$(basename "$ws")"
      done
    else
      echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace/$(basename "$WORKSPACE")"
    fi
    exit 0
  fi

elif [[ -n "$CONTAINER_STATE" ]]; then
  # Container exists but is stopped
  EXISTING_WORKSPACE=$(grep "^${CONTAINER_NAME}|" "$STATE_FILE" 2>/dev/null | cut -d'|' -f2 || echo "")

  if [[ -z "$EXISTING_WORKSPACE" ]]; then
    # Orphaned container (no state entry), clean it up
    echo "Removing orphaned stopped container '$CONTAINER_NAME'..."
    container rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
  elif [[ "$PERSISTENT" == false && "$EXISTING_WORKSPACE" != "$WORKSPACE" ]]; then
    # Transient with different workspace, replace it
    echo "Replacing stopped transient container (different workspace)..."
    container rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    sed -i.bak "/^${CONTAINER_NAME}|/d" "$STATE_FILE" 2>/dev/null || true
  else
    # Same workspace (or persistent) — resume
    ensure_ssh_config "$CONTAINER_NAME"
    echo "Resuming stopped container '$CONTAINER_NAME'..."
    container start "$CONTAINER_NAME"
    echo ""
    echo "✓ Container resumed"
    echo ""
    echo "  SSH:    ssh $CONTAINER_NAME"
    if [[ "$EXISTING_WORKSPACE" == *,* ]]; then
      IFS=',' read -ra _EWS <<< "$EXISTING_WORKSPACE"
      for ws in "${_EWS[@]}"; do
        echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace/$(basename "$ws")"
      done
    else
      echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace/$(basename "$EXISTING_WORKSPACE")"
    fi
    exit 0
  fi
fi

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
# A port is unavailable if something is actively listening on it, OR if it's
# already reserved by another container in the state file — the latter
# catches stopped containers, which don't hold an lsof binding while paused.
port_reserved() {
  local port="$1"
  lsof -i ":$port" >/dev/null 2>&1 && return 0
  awk -F'|' -v p="$port" '$3==p {found=1} END{exit !found}' "$STATE_FILE" 2>/dev/null && return 0
  return 1
}

if [[ -z "$SSH_PORT" ]]; then
  BASE_PORT=$(profile_port "$PROFILE")
  SSH_PORT=$BASE_PORT
  while port_reserved "$SSH_PORT"; do
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
        local key="${line%%=*}"
        local val="${line#*=}"
        # Expand $VAR or ${VAR} references from host environment
        if [[ "$val" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
          local ref="${BASH_REMATCH[1]}"
          val="${!ref:-}"
          if [[ -z "$val" ]]; then
            echo "   WARN: $ref not set in environment, skipping $key"
            continue
          fi
        fi
        ENV_FILE_ARGS+=("-e" "${key}=${val}")
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
MOUNT_ARGS=()

if [[ "$MULTI_WORKSPACE" == true ]]; then
  for ws in "${WORKSPACES[@]}"; do
    MOUNT_ARGS+=(--volume "${ws}:/workspace/$(basename "$ws")")
  done
else
  MOUNT_ARGS+=(--volume "${WORKSPACE}:/workspace/$(basename "$WORKSPACE")")
fi

MOUNT_ARGS+=(--volume "${KEY_FILE}.pub:/tmp/pubkey/authorized_keys:ro")

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
      # Directory-level bind mounts onto /root/.claude have proven unreliable
      # with this container runtime (silently fail to attach on restart), so
      # mount the individual files that actually hold login state instead.
      CONFIG_JSON="$AUTH_DIR/claude.json"
      [[ -f "$CONFIG_JSON" ]] || echo '{}' > "$CONFIG_JSON"
      MOUNT_ARGS+=(--volume "${CONFIG_JSON}:/root/.claude.json")

      CREDENTIALS_JSON="$AUTH_DIR/.credentials.json"
      [[ -f "$CREDENTIALS_JSON" ]] || echo '{}' > "$CREDENTIALS_JSON"
      MOUNT_ARGS+=(--volume "${CREDENTIALS_JSON}:/root/.claude/.credentials.json")
      ;;
  esac
fi

# Claude projects mount (for cost tracking via codeburn)
if [[ "$PROFILE" =~ ^(claude|opencode|pi)$ ]]; then
  CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"
  mkdir -p "$CLAUDE_PROJECTS_DIR"
  MOUNT_ARGS+=(--volume "${CLAUDE_PROJECTS_DIR}:/root/.claude/projects")
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
if [[ "$MULTI_WORKSPACE" == true ]]; then
  echo "   Workspaces:"
  for ws in "${WORKSPACES[@]}"; do
    echo "     /workspace/$(basename "$ws") → $ws"
  done
else
  echo "   Workspace: $WORKSPACE"
fi
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
echo "${CONTAINER_NAME}|${WORKSPACE}|${SSH_PORT}|${CONTAINER_TYPE}|${PROFILE}" >> "$STATE_FILE"

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
if [[ "$MULTI_WORKSPACE" == true ]]; then
  for ws in "${WORKSPACES[@]}"; do
    echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace/$(basename "$ws")"
  done
else
  echo "  VSCode: code --remote ssh-remote+$CONTAINER_NAME /workspace/$(basename "$WORKSPACE")"
fi
echo ""
if [[ "$PERSISTENT" == false ]]; then
  echo "  Type:   Transient (will auto-replace when switching workspaces)"
else
  echo "  Type:   Persistent (dedicated, never auto-replaced)"
fi
echo ""
echo "  List:    container-dev list"
echo "  Pause:   container stop $CONTAINER_NAME"
echo "  Resume:  container start $CONTAINER_NAME"
echo "  Delete:  container-dev delete $CONTAINER_NAME"
