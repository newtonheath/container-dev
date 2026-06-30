# container-dev

Containerized development environments for macOS. Each profile is an isolated Fedora 44 container accessible via SSH, with the user's repo bind-mounted at `/workspace`.

## Runtime

Uses Apple's `container` CLI (not Docker or Podman). Commands are `container build`, `container run`, `container list`, `container stop`, `container image list`, etc.

## Command Interface

Main entry point: `container-dev` (symlinked to `~/.local/bin/container-dev` by `install.sh`)

Subcommands:
- `container-dev start <profile> [--persistent]` → `bin/start.sh`
- `container-dev stop <container-name>` → `bin/stop.sh`
- `container-dev list` → `bin/list.sh`
- `container-dev persist` → `bin/persist.sh`

## Key Files

- `bin/container-dev` — Main command wrapper (dispatches to subcommands)
- `bin/start.sh` — Builds image if needed, runs container, manages state, writes SSH config
- `bin/stop.sh` — Stops and removes container, warns for persistent, cleans up state
- `bin/list.sh` — Shows all containers with transient/persistent status
- `bin/persist.sh` — Converts transient container to persistent (in progress)
- `profiles/<name>/Dockerfile` — Fedora 44 base, openssh-server, tool installation
- `profiles/<name>/entrypoint.sh` — Copies SSH pubkey, writes config, starts sshd
- `profiles/<name>/sshd_config` — Hardened SSH config (pubkey only, no password)

## Profiles

### Current Profiles

| Profile | Tool | Backend | Auth | Port Base |
|---------|------|---------|------|-----------|
| `claude` | Claude Code | Claude API | Auto-detected (vertex/api/web) | 2222 |
| `claude-vertex` | Claude Code | Vertex AI | gcloud ADC (deprecated) | 2222 |
| `claude-pro-api` | Claude Code | Claude API | API key (deprecated) | 2223 |
| `claude-pro-web` | Claude Code | Claude API | Browser OAuth (deprecated) | 2224 |

**Note:** The three old Claude profiles are deprecated. Use the unified `claude` profile instead.

### Planned Profiles (Phase 3-4)

| Profile | Tool | Backend | Auth | Port Base |
|---------|------|---------|------|-----------|
| `opencode` | Opencode | Claude API | Auto-detected | 2230 |
| `opencode-local` | Opencode | llama.cpp | N/A | 2231 |
| `pi` | Pi | Claude API | Auto-detected | 2240 |
| `pi-local` | Pi | llama.cpp | N/A | 2241 |

## Container Lifecycle

### Transient Containers (Default)

- **Name pattern**: `{profile}-transient` (e.g., `claude-transient`)
- **Behavior**: Auto-replaced when workspace changes
- **Use case**: Quick experiments, many repos
- **Created with**: `container-dev start <profile>`

### Persistent Containers (Opt-in)

- **Name pattern**: `{profile}-{workspace-slug}` (e.g., `claude-importantproject`)
- **Behavior**: Never auto-replaced, stays until explicitly stopped
- **Use case**: Long-lived projects
- **Created with**: `container-dev start <profile> --persistent`

### State Tracking

State file: `~/.config/container-dev/state`

Format: `{container-name}|{workspace-path}|{ssh-port}|{type}`

Example:
```
claude-transient|/Users/you/experiments/test|2222|transient
claude-bigproject|/Users/you/work/bigproject|2223|persistent
opencode-local-research|/Users/you/research/ml|2231|persistent
```

## Authentication (Claude-based profiles)

### Machine-Level Configuration

Config file: `~/.config/container-dev/config`

```bash
# Auto-detected on first run, or manually override:
CLAUDE_AUTH_TYPE=vertex  # Options: vertex, api, web

# Optional override (takes precedence):
FORCE_CLAUDE_AUTH=vertex
```

### Auto-Detection Logic

1. If `~/.config/gcloud/application_default_credentials.json` exists → `vertex`
2. Else if `ANTHROPIC_API_KEY` in env or `.env` → `api`
3. Else → `web` (browser OAuth fallback)

### Auth-Specific Volume Mounts

**Vertex AI:**
```
~/.config/gcloud/application_default_credentials.json → /root/.config/gcloud/... (ro)
```

**Browser OAuth:**
```
~/.config/container-dev/auth/claude → /root/.claude (rw, token persistence)
```

**API Key:**
- No additional mounts (key passed via env var)

## Volume Mounts

### Base Mounts (All Profiles)

| Source (host) | Destination (container) | Mode |
|---|---|---|
| `{workspace}` | `/workspace` | rw |
| `~/.config/container-dev/keys/container_ed25519.pub` | `/tmp/pubkey/authorized_keys` | ro |

### Auth Mounts (Claude-based profiles only)

Conditional based on detected auth type (see above).

### Backend Mounts (Local profiles only)

For profiles matching `*-local` pattern:

| Source (host) | Destination (container) | Mode |
|---|---|---|
| `~/.config/container-dev/models` | `/root/.cache/models` | ro |

## SSH Configuration

### SSH Keypair

- **Location**: `~/.config/container-dev/keys/container_ed25519`
- **Generated**: Once by `start.sh` if absent
- **Shared**: Across all profiles
- **Security**: Dedicated keypair, never uses user's personal SSH keys

### SSH Config Entries

Auto-managed by `start.sh` and `stop.sh`.

**Format:**
```
Host {container-name}
    HostName 127.0.0.1
    Port {ssh-port}
    User root
    IdentityFile ~/.config/container-dev/keys/container_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

**Examples:**
- `ssh claude-transient`
- `ssh claude-importantproject`
- `ssh opencode-local-research`

## Port Allocation

### Strategy

- Each profile has a **base port** (defined in `profile_port()` in `start.sh`)
- Transient container uses base port
- Persistent containers get next available port if base is taken
- Auto-increments to avoid conflicts

### Port Map

```bash
profile_port() {
  case "$1" in
    claude)          echo 2222 ;;
    opencode)        echo 2230 ;;
    opencode-local)  echo 2231 ;;
    pi)              echo 2240 ;;
    pi-local)        echo 2241 ;;
    # Legacy (deprecated)
    claude-vertex)   echo 2222 ;;
    claude-pro-api)  echo 2223 ;;
    claude-pro-web)  echo 2224 ;;
    *)               echo 2299 ;;
  esac
}
```

## Environment Variables Passed to Container

`start.sh` sets these env vars for container use:

```bash
WORKSPACE_PATH=/Users/you/path/to/workspace
CONTAINER_NAME=claude-importantproject
CLAUDE_AUTH_TYPE=vertex
```

These are used by `entrypoint.sh` to:
- Write MOTD with workspace info
- Configure PS1 prompt
- Generate tool-specific config

## Adding a New Profile

### 1. Create Profile Directory

```
profiles/newtool/
├── Dockerfile
├── entrypoint.sh
├── sshd_config
└── env.example (optional)
```

### 2. Update Port Map

Add case to `profile_port()` in `bin/start.sh`:

```bash
newtool)         echo 2250 ;;
newtool-local)   echo 2251 ;;
```

### 3. Dockerfile Pattern

```dockerfile
FROM fedora:44

# Base tooling (git, ssh, compilers, etc.)
RUN dnf -y update && dnf -y install openssh-server ... && dnf clean all

# SSH setup
RUN ssh-keygen -A && mkdir -p /root/.ssh && chmod 700 /root/.ssh && passwd -d root
COPY sshd_config /etc/ssh/sshd_config

# Install tool
RUN npm install -g your-tool  # or pip, binary, etc.

# Entrypoint
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

WORKDIR /workspace
EXPOSE 22
CMD ["/usr/local/bin/entrypoint.sh"]
```

### 4. Entrypoint Pattern

```bash
#!/usr/bin/env bash
set -euo pipefail

# Copy SSH key
if [[ -f /tmp/pubkey/authorized_keys ]]; then
  cp /tmp/pubkey/authorized_keys /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
fi

# MOTD
cat > /etc/motd <<MOTD
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Container: ${CONTAINER_NAME:-unknown}
  Profile:   newtool
  Workspace: ${WORKSPACE_PATH:-/workspace}
MOTD

# Prompt customization
WORKSPACE_NAME=$(basename "${WORKSPACE_PATH:-/workspace}")
echo "export PS1='[\u@${WORKSPACE_NAME}:\w]\\$ '" >> /root/.bashrc
echo 'cd /workspace' >> /root/.bashrc

# Tool-specific configuration
mkdir -p /root/.newtool
cat > /root/.newtool/config.json <<CONFIG
{
  "setting": "value"
}
CONFIG

exec /usr/sbin/sshd -D
```

### 5. Auth Detection (for Claude-based backends)

If your tool uses Claude as a backend, add detection logic in `start.sh`:

```bash
# In start.sh, volume mount section:
if [[ "$PROFILE" =~ ^(claude|opencode|pi|newtool)$ ]]; then
  case "$CLAUDE_AUTH_TYPE" in
    vertex) ... ;;
    api) ... ;;
    web) ... ;;
  esac
fi
```

### 6. Local Backend (for llama.cpp)

For `*-local` profiles, model mounts are auto-applied. Configure in `entrypoint.sh`:

```bash
# Start llama.cpp server
MODEL_PATH="${LLAMA_MODEL_PATH:-/root/.cache/models/default-model.gguf}"
if [[ -f "$MODEL_PATH" ]]; then
  llama-server --model "$MODEL_PATH" --port 8080 --host 127.0.0.1 &
fi

# Configure tool to use llama backend
cat > /root/.newtool/config.json <<CONFIG
{
  "backend": "llama",
  "endpoint": "http://127.0.0.1:8080"
}
CONFIG
```

## Implementation Status

### Phase 1: Core Infrastructure ✅
- [x] `install.sh` - Symlink installer
- [x] `bin/container-dev` - Main command wrapper
- [x] `bin/list.sh` - Container listing
- [x] `bin/persist.sh` - Transient→persistent conversion (partial)
- [x] `bin/start.sh` - Transient/persistent lifecycle
- [x] `bin/stop.sh` - Persistent warnings
- [x] State file management

### Phase 2: Auth Unification ✅
- [x] Auth auto-detection logic
- [x] Unified `claude` profile
- [x] Machine-level config file
- [x] Backward compatibility (old profiles still work)

### Phase 3: Opencode Profiles 🚧
- [ ] `profiles/opencode/` - Opencode with Claude
- [ ] `profiles/opencode-local/` - Opencode with llama.cpp
- [ ] Model download helpers
- [ ] Testing

### Phase 4: Pi Profiles 🚧
- [ ] `profiles/pi/` - Pi with Claude
- [ ] `profiles/pi-local/` - Pi with llama.cpp

### Phase 5: Polish 🚧
- [ ] Complete `persist.sh` implementation
- [ ] Comprehensive testing
- [ ] Migration guide for old profiles

## Troubleshooting

### Stale State File

If containers aren't auto-replacing:
```bash
cat ~/.config/container-dev/state
# Remove stale entries manually
```

### Port Conflicts

Check which ports are in use:
```bash
lsof -i :2222
lsof -i :2223
```

### Auth Detection Issues

Force a specific auth type:
```bash
echo "FORCE_CLAUDE_AUTH=api" >> ~/.config/container-dev/config
```

### SSH Config Pollution

Old entries can accumulate. Clean up manually:
```bash
# Back up first
cp ~/.ssh/config ~/.ssh/config.bak

# Remove container-dev entries
sed -i '/^Host .*-transient$/,/^$/d' ~/.ssh/config
sed -i '/^Host claude-/,/^$/d' ~/.ssh/config
```
