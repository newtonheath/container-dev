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

# shellcheck source=../lib/config.sh
source "$PROJECT_DIR/lib/config.sh"
cfg_validate

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
  # auth.force in config/container-dev.yaml (or a user config.yaml override)
  # short-circuits; otherwise walk auth.detect in declared order.
  local forced
  forced=$(cfg_auth_force)
  if [[ -n "$forced" ]]; then
    echo "$forced"
    return
  fi
  cfg_auth_detect
}

# ---------------------------------------------------------------------------
# usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: container-dev create <profile> [dirs...] [--persistent] [options]

Creates a new container or resumes a stopped one.

Arguments:
  profile     Profile name: claude, codex, cline, opencode, pi
  dirs        Optional directories to mount (default: current directory)
              Each is mounted as /workspace/<dirname> in the container

Flags:
  --persistent         Create dedicated container for this workspace (never auto-replaced)
                       Default: transient (auto-replaced when switching workspaces)

Options:
  --name <slug>                 Container name suffix (auto-derived from workspace directory names
                                if not provided)
  --config <name>               Named per-instance config, for profiles that support it:
                                  cline:    reads ~/.config/container-dev/cline/<name>/;
                                            without this flag the flat
                                            ~/.config/container-dev/cline/ is used.
                                  opencode: selects a backend declared under
                                            profiles.opencode.configs in
                                            config/container-dev.yaml (currently: work-vertex).
                                Names the container <profile>-<name>-* so different
                                configs are distinguishable in lists.
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

  # Cline with a named config (provider visible in container name and list)
  container-dev create cline --config claude     # → cline-claude-transient
  container-dev create cline --config mini4      # → cline-mini4-transient

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

  # OpenAI Codex with host-persisted ChatGPT/API authentication
  container-dev create codex --persistent
  ssh codex-importantproject

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
CONFIG_NAME=""
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
    --config)         CONFIG_NAME="$2"; shift 2 ;;
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

# With --config <name>, the name prefix becomes "<profile>-<name>" so
# containers are self-describing: cline-claude-transient, cline-mini4-myproject,
# opencode-work-vertex-mystack. IMAGE_NAME stays <profile>-img (same Dockerfile
# regardless of config).
NAME_PREFIX="$PROFILE"
if [[ -n "$CONFIG_NAME" ]]; then
  NAME_PREFIX="${PROFILE}-${CONFIG_NAME}"
fi

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
  CONTAINER_NAME="${NAME_PREFIX}-${WORKSPACE_SLUG}"
  CONTAINER_TYPE="persistent"
else
  CONTAINER_NAME="${NAME_PREFIX}-transient"
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

if ! cfg_profile_exists "$PROFILE"; then
  echo "ERROR: profile '$PROFILE' is not declared in config/container-dev.yaml" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# named-config resolution (opencode's --config; cline keeps its own dynamic
# per-directory resolution below, since its config names aren't an
# enumerable YAML set — see config/container-dev.yaml's cline entry)
# ---------------------------------------------------------------------------
OPENCODE_CONFIG_AUTH="none"
if [[ -n "$CONFIG_NAME" && "$PROFILE" != "cline" ]]; then
  if ! cfg_has ".profiles.\"$PROFILE\".configs"; then
    echo "ERROR: profile '$PROFILE' has no named configs (see config/container-dev.yaml)" >&2
    exit 1
  fi
  if ! cfg_profile_config_exists "$PROFILE" "$CONFIG_NAME"; then
    echo "ERROR: unknown config '$CONFIG_NAME' for profile '$PROFILE'" >&2
    echo "  Known configs: $(cfg_list ".profiles.\"$PROFILE\".configs | keys" | paste -sd',' - | sed 's/,/, /g')" >&2
    exit 1
  fi
  if [[ "$PROFILE" == "opencode" ]]; then
    OPENCODE_CONFIG_AUTH=$(cfg_profile_config_auth "$PROFILE" "$CONFIG_NAME")
    case "$OPENCODE_CONFIG_AUTH" in
      vertex) ;;  # wired up below
      openai-api|local)
        echo "ERROR: opencode config '$CONFIG_NAME' (auth: $OPENCODE_CONFIG_AUTH) is declared" >&2
        echo "  in config/container-dev.yaml but not yet implemented — see the" >&2
        echo "  'Codex CLI — deferred' note in docs/plan-network-policy.md." >&2
        exit 1
        ;;
      *)
        echo "ERROR: opencode config '$CONFIG_NAME' has unknown auth type '$OPENCODE_CONFIG_AUTH'" >&2
        exit 1
        ;;
    esac
  fi
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
if [[ "$PROFILE" == "claude" ]]; then
  CLAUDE_AUTH_TYPE=$(detect_claude_auth)
  echo "Detected Claude auth: $CLAUDE_AUTH_TYPE"
fi

# Codex keeps its own CLI/IDE state under CODEX_HOME. Mounting the complete
# directory preserves file-backed ChatGPT login state, config, sessions, and
# other local Codex data across transient container replacement.
CODEX_HOME_HOST=""
CODEX_AUTH_TYPE="none"
if [[ "$PROFILE" == "codex" ]]; then
  CODEX_HOME_HOST="${CODEX_HOME:-$HOME/.codex}"
  if [[ "$CODEX_HOME_HOST" != /* ]]; then
    echo "ERROR: CODEX_HOME must be an absolute path: $CODEX_HOME_HOST" >&2
    exit 1
  fi
  mkdir -p "$CODEX_HOME_HOST"
  chmod 700 "$CODEX_HOME_HOST" 2>/dev/null || true
  [[ -f "$CODEX_HOME_HOST/auth.json" ]] && CODEX_AUTH_TYPE="cached"
fi

# ---------------------------------------------------------------------------
# detect provider for Cline profile
# ---------------------------------------------------------------------------
CLINE_PROVIDER="none"
if [[ "$PROFILE" == "cline" ]]; then
  # --config <name> uses ~/.config/container-dev/cline/<name>/ as config dir
  # No --config flag uses the flat ~/.config/container-dev/cline/ (default)
  if [[ -n "$CONFIG_NAME" ]]; then
    CLINE_HOST_DIR="$CONFIG_DIR/cline/$CONFIG_NAME"
  else
    CLINE_HOST_DIR="$CONFIG_DIR/cline"
  fi
  mkdir -p "$CLINE_HOST_DIR"
  CLINE_PROVIDER_FILE="$CLINE_HOST_DIR/provider"
  if [[ -f "$CLINE_PROVIDER_FILE" ]]; then
    CLINE_PROVIDER=$(cat "$CLINE_PROVIDER_FILE")
  else
    CLINE_PROVIDER="anthropic"
    echo "anthropic" > "$CLINE_PROVIDER_FILE"
    echo "Defaulting Cline provider to: anthropic (saved to $CLINE_HOST_DIR/provider)"
  fi
fi

# ---------------------------------------------------------------------------
# resource limits
# ---------------------------------------------------------------------------
if [[ -n "$SIZE" ]]; then
  read -r CPUS MEM <<< "$(cfg_resource "$SIZE")"
fi
if [[ -z "$CPUS" || -z "$MEM" ]]; then
  read -r DEFAULT_CPUS DEFAULT_MEM <<< "$(cfg_resource "$(cfg_get '.defaults.size' 'medium')")"
  CPUS="${CPUS:-$DEFAULT_CPUS}"
  MEM="${MEM:-$DEFAULT_MEM}"
fi

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
  BASE_PORT=$(cfg_profile_port "$PROFILE")
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
        if [[ "$PROFILE" == "codex" && ( "$key" == "CODEX_HOME" || "$key" == "CODEX_AUTH_TYPE" ) ]]; then
          echo "   NOTE: ignoring $key from $file; it is managed by container-dev"
          continue
        fi
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
        if [[ "$PROFILE" == "codex" && ( "$varname" == "CODEX_HOME" || "$varname" == "CODEX_AUTH_TYPE" ) ]]; then
          echo "   NOTE: ignoring $varname from $file; it is managed by container-dev"
          continue
        fi
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

# Check both the ambient shell and the already-expanded env-file arguments.
# This lets users keep secrets in ~/.config/container-dev/env without making
# create.sh source that file into the host shell.
env_args_has_value() {
  local name="$1" entry
  [[ -n "${!name:-}" ]] && return 0
  for entry in "${ENV_FILE_ARGS[@]}"; do
    [[ "$entry" == "$name="* ]] || continue
    [[ -n "${entry#*=}" ]] && return 0
  done
  return 1
}

# Load user-level env file first (personal settings)
load_env_file "$USER_ENV_FILE"

# Load profile-level env file second (can override user settings)
load_env_file "$ENV_FILE"

if [[ "$PROFILE" == "codex" && "$CODEX_AUTH_TYPE" == "none" ]]; then
  if [[ -f "$CODEX_HOME_HOST/auth.json" ]]; then
    CODEX_AUTH_TYPE="cached"
  elif env_args_has_value CODEX_ACCESS_TOKEN || env_args_has_value OPENAI_API_KEY; then
    CODEX_AUTH_TYPE="token"
  else
    CODEX_AUTH_TYPE="setup-required"
    echo "WARN: Codex has no cached auth.json or token in the environment" >&2
    echo "  Set OPENAI_API_KEY/CODEX_ACCESS_TOKEN or run 'codex login --device-auth' inside the container" >&2
  fi
fi

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

# add_cfg_mount <src:dst[:mode]> — split a config-declared mount line into a
# --volume arg. Paths in config/container-dev.yaml never contain ':', so a
# plain split is safe.
add_cfg_mount() {
  local line="$1" src dst mode
  IFS=':' read -r src dst mode <<< "$line"
  if [[ -n "$mode" ]]; then
    MOUNT_ARGS+=(--volume "${src}:${dst}:${mode}")
  else
    MOUNT_ARGS+=(--volume "${src}:${dst}")
  fi
}

# Auth-specific mounts (Claude Code profile, and opencode's work-vertex config)
if [[ "$PROFILE" == "claude" ]]; then
  case "$CLAUDE_AUTH_TYPE" in
    vertex)
      if [[ -f "$HOME/.config/gcloud/application_default_credentials.json" ]]; then
        while IFS= read -r line; do add_cfg_mount "$line"; done < <(cfg_auth_mounts vertex)
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
      while IFS= read -r line; do
        src="${line%%:*}"
        [[ -f "$src" ]] || echo '{}' > "$src"
        add_cfg_mount "$line"
      done < <(cfg_auth_mounts web)
      ;;
  esac
fi

if [[ "$PROFILE" == "opencode" && "$OPENCODE_CONFIG_AUTH" == "vertex" ]]; then
  if [[ -f "$HOME/.config/gcloud/application_default_credentials.json" ]]; then
    while IFS= read -r line; do add_cfg_mount "$line"; done < <(cfg_auth_mounts vertex)
  else
    echo "WARN: --config $CONFIG_NAME uses Vertex auth but gcloud ADC not found" >&2
    echo "  Run 'gcloud auth application-default login' to set up credentials" >&2
  fi
  echo "NOTE: --config $CONFIG_NAME mounts the Vertex ADC file, but opencode's" >&2
  echo "  provider config (opencode.json) does not yet seed a vertex provider" >&2
  echo "  automatically — see the Plan 1 scope note in" >&2
  echo "  docs/plan-network-policy.md." >&2
fi

# Claude Code settings mount (host-defined model + effort defaults, LIVE)
# The host file is the single source of truth for model + effort. We bind-mount
# its PARENT DIRECTORY read-only at /tmp/claude-host (NOT the file directly): a
# single-file virtiofs mount is pinned to the file's inode, so editing the host
# file (editors save atomically = new inode) silently breaks the mount and the
# file vanishes inside the container. A directory mount is inode-stable, so host
# edits are picked up live. entrypoint.sh refreshes a writable copy into
# /root/.claude/settings.json and exports effort on each login (see below).
if [[ "$PROFILE" == "claude" ]]; then
  CLAUDE_SETTINGS_MOUNT=$(cfg_mount_group claude-settings | head -1)
  CLAUDE_SETTINGS_DIR="${CLAUDE_SETTINGS_MOUNT%%:*}"
  CLAUDE_SETTINGS_SRC="$CLAUDE_SETTINGS_DIR/settings.json"
  mkdir -p "$CLAUDE_SETTINGS_DIR"
  if [[ ! -f "$CLAUDE_SETTINGS_SRC" ]]; then
    cat > "$CLAUDE_SETTINGS_SRC" <<'SETTINGS'
{
  "theme": "dark",
  "model": "sonnet",
  "effortLevel": "high",
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5@20251001"
  }
}
SETTINGS
  fi
  while IFS= read -r line; do add_cfg_mount "$line"; done < <(cfg_mount_group claude-settings)
fi

# Claude projects mount (for cost tracking via codeburn)
if [[ "$PROFILE" == "claude" ]]; then
  mkdir -p "$HOME/.claude/projects"
  while IFS= read -r line; do add_cfg_mount "$line"; done < <(cfg_mount_group claude-projects)
fi

# Cline config mount (host-defined provider + credentials, LIVE)
# The host directory is bind-mounted read-only at /tmp/cline-host. On each
# interactive login entrypoint.sh re-seeds ~/.cline/data/ from it, so host
# edits take effect on the next cline launch without recreating the container.
# A directory mount is used (not a single-file mount) for inode stability.
if [[ "$PROFILE" == "cline" ]]; then
  MOUNT_ARGS+=(--volume "${CLINE_HOST_DIR}:/tmp/cline-host:ro")

fi

# Codex CLI and its VS Code extension share CODEX_HOME. Keep this mount
# writable so device-auth or API-key login can refresh auth.json in place.
if [[ "$PROFILE" == "codex" ]]; then
  MOUNT_ARGS+=(--volume "${CODEX_HOME_HOST}:/root/.codex")
fi

# Model mounts (local-backend profiles, per config/container-dev.yaml)
if [[ "$(cfg_profile_backend "$PROFILE")" == "local" ]]; then
  mkdir -p "$CONFIG_DIR/models"
  while IFS= read -r line; do add_cfg_mount "$line"; done < <(cfg_profile_mounts "$PROFILE")
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
if [[ "$PROFILE" == "claude" ]]; then
  case "$CLAUDE_AUTH_TYPE" in
    vertex)
      # Prefer the canonical Vertex settings from the machine-level env file
      # (written by the gcloud/Vertex setup) so we don't inherit a stale
      # ANTHROPIC_VERTEX_PROJECT_ID from the ambient shell. Falls back to the
      # shell environment when the file is absent.
      VERTEX_ENV_FILE="$HOME/.config/claude-code-vertex/env.sh"
      if [[ -f "$VERTEX_ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$VERTEX_ENV_FILE"
      fi
      # CLAUDE_CODE_USE_VERTEX is a Claude Code built-in flag; it is derived
      # from CLAUDE_AUTH_TYPE=vertex here rather than being a user-facing knob.
      CONTAINER_ENV+=(-e "CLAUDE_CODE_USE_VERTEX=1")
      CONTAINER_ENV+=(-e "ANTHROPIC_VERTEX_PROJECT_ID=${ANTHROPIC_VERTEX_PROJECT_ID:-}")
      CONTAINER_ENV+=(-e "CLOUD_ML_REGION=${CLOUD_ML_REGION:-global}")
      ;;
    api)
      CONTAINER_ENV+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}")
      ;;
  esac
fi

# Auth env vars for Cline profile
if [[ "$PROFILE" == "cline" ]]; then
  CONTAINER_ENV+=(-e "CLINE_PROVIDER=$CLINE_PROVIDER")
  case "$CLINE_PROVIDER" in
    anthropic)
      CONTAINER_ENV+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}")
      ;;
    # openai-compat (mini4 etc): no auth env var needed; URL and model come
    # from the mounted openai.json which entrypoint.sh reads at login time.
  esac
fi

# Auth env var for OpenCode/Pi profiles (Anthropic API key only, for now —
# these tools have their own provider/config systems, unrelated to Claude
# Code's settings.json or CLAUDE_AUTH_TYPE, so they're kept independent).
if [[ "$PROFILE" =~ ^(opencode|pi)$ ]]; then
  CONTAINER_ENV+=(-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}")
fi

if [[ "$PROFILE" == "codex" ]]; then
  CONTAINER_ENV+=(-e "CODEX_HOME=/root/.codex")
  CONTAINER_ENV+=(-e "CODEX_AUTH_TYPE=$CODEX_AUTH_TYPE")
  [[ -n "${OPENAI_API_KEY:-}" ]] && CONTAINER_ENV+=(-e "OPENAI_API_KEY=$OPENAI_API_KEY")
  [[ -n "${CODEX_ACCESS_TOKEN:-}" ]] && CONTAINER_ENV+=(-e "CODEX_ACCESS_TOKEN=$CODEX_ACCESS_TOKEN")
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
# build base image if needed
# ---------------------------------------------------------------------------
# Every profile Dockerfile builds `FROM container-dev-base:latest` instead of
# repeating the Fedora + common-tooling + SSH layer — see profiles/_base/.
# Like profile images, this isn't auto-rebuilt on Dockerfile changes; force a
# rebuild with `container image rm container-dev-base` (and then the profile
# images too, since they were built FROM the old base).
BASE_IMAGE_NAME="container-dev-base"
BASE_DOCKERFILE="$PROJECT_DIR/profiles/_base/Dockerfile"
if container image list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$BASE_IMAGE_NAME"; then
  echo ">> Base image '$BASE_IMAGE_NAME' exists"
else
  echo ">> Building $BASE_IMAGE_NAME from $BASE_DOCKERFILE ..."
  container build -t "$BASE_IMAGE_NAME" --file "$BASE_DOCKERFILE" "$PROJECT_DIR/profiles/_base"
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
if [[ "$CODEX_AUTH_TYPE" != "none" ]]; then
  echo "   Auth:      Codex ($CODEX_AUTH_TYPE)"
fi
if [[ "$OPENCODE_CONFIG_AUTH" != "none" ]]; then
  echo "   Config:    $CONFIG_NAME (auth: $OPENCODE_CONFIG_AUTH)"
fi
if [[ "$CLINE_PROVIDER" != "none" ]]; then
  if [[ -n "$CONFIG_NAME" ]]; then
    echo "   Provider:  Cline ($CONFIG_NAME / $CLINE_PROVIDER)"
  else
    echo "   Provider:  Cline ($CLINE_PROVIDER)"
  fi
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
