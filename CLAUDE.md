# container-dev

Containerized development environments for macOS. Each profile is an isolated Fedora 44 container accessible via SSH, with the user's repo bind-mounted at `/workspace`.

## Runtime

Uses Apple's `container` CLI (not Docker or Podman). Commands are `container build`, `container run`, `container list`, `container stop`, `container image list`, etc.

## Command Interface

Main entry point: `container-dev` (symlinked to `~/.local/bin/container-dev` by `install.sh`)

Subcommands:
- `container-dev create <profile> [--persistent]` → `bin/create.sh`
- `container-dev delete <container-name>` → `bin/delete.sh`
- `container-dev list` → `bin/list.sh`
Pause/resume uses native Apple `container` CLI directly:
- `container stop <container-name>` — pause (frees memory, preserves filesystem)
- `container start <container-name>` — resume a paused container

## Key Files

- `bin/container-dev` — Main command wrapper (dispatches to subcommands)
- `bin/create.sh` — Builds image if needed, runs or resumes container, manages state, writes SSH config
- `bin/delete.sh` — Permanently removes container, cleans up state and SSH config
- `bin/list.sh` — Shows all containers (running and stopped) with status, reconciles stale entries
- `profiles/<name>/Dockerfile` — Fedora 44 base, openssh-server, tool installation
- `profiles/<name>/entrypoint.sh` — Copies SSH pubkey, writes config, starts sshd
- `profiles/<name>/sshd_config` — Hardened SSH config (pubkey only, no password)

## Profiles

### Current Profiles

| Profile | Tool | Backend | Auth | Port Base |
|---------|------|---------|------|-----------|
| `claude` | Claude Code | Claude API | Auto-detected (vertex/api/web) | 2222 |
| `cline` | Cline | Anthropic API or OpenAI-compat | API key (`anthropic`) or endpoint URL (`mini4` or any named LAN server) | 2260 |
| `opencode` | [OpenCode](https://opencode.ai) | Anthropic API | `ANTHROPIC_API_KEY` env var, seeded into `~/.config/opencode/opencode.json` via `{env:...}` substitution | 2230 |
| `pi` | [Pi](https://pi.dev) | Anthropic API | `ANTHROPIC_API_KEY` env var, read directly by the `pi` CLI | 2240 |

`opencode` and `pi` are independent of `CLAUDE_AUTH_TYPE`/vertex/web — they're
separate tools with their own config formats, currently wired for API-key auth
only (see `create.sh`'s `^(opencode|pi)$` block). The `cline` profile also
bakes the Cline VS Code extension `.vsix` (fetched from Open VSX at build
time) into the image; `entrypoint.sh` auto-installs it into
`~/.vscode-server` once VS Code Server appears there on first Remote-SSH
connect, so the chat panel shows up without a manual "Install in SSH: ..."
step.

### Planned Profiles (Phase 3-4)

| Profile | Tool | Backend | Auth | Port Base |
|---------|------|---------|------|-----------|
| `opencode-local` | Opencode | llama.cpp | N/A | 2231 |
| `pi-local` | Pi | llama.cpp | N/A | 2241 |

## Container Lifecycle

### Transient Containers (Default)

- **Name pattern**: `{profile}-transient` (e.g., `claude-transient`)
- **Behavior**: Auto-replaced when workspace changes
- **Use case**: Quick experiments, many repos
- **Created with**: `container-dev create <profile>`

### Persistent Containers (Opt-in)

- **Name pattern**: `{profile}-{workspace-slug}` (e.g., `claude-importantproject`)
- **Behavior**: Never auto-replaced, stays until explicitly deleted
- **Use case**: Long-lived projects
- **Created with**: `container-dev create <profile> --persistent`

### Container States

- **Running**: container is active, SSH accessible, consuming memory
- **Stopped**: container paused via `container stop <name>`, filesystem preserved, memory freed. Resume with `container start <name>` or `container-dev create <profile>`.
- **Deleted**: container permanently removed via `container-dev delete <name>`, SSH config and state cleaned up

### State Tracking

State file: `~/.config/container-dev/state`

Format: `{container-name}|{workspace-path}|{ssh-port}|{type}|{profile}`

Example:
```
claude-transient|/Users/you/experiments/test|2222|transient|claude
claude-bigproject|/Users/you/work/bigproject|2223|persistent|claude
opencode-local-research|/Users/you/research/ml|2231|persistent|opencode-local
```

The `list` command reconciles stale entries: if a container was removed outside of `container-dev` (e.g., via `container rm` or `container prune`), `list` automatically cleans up orphaned state file and SSH config entries.

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

### Claude Code Settings Mount (Claude-based profiles only)

| Source (host) | Destination (container) | Mode |
|---|---|---|
| `~/.config/container-dev/claude/` (directory) | `/tmp/claude-host` | ro |

Host-defined **model + effort defaults**. The host config **directory** is
bind-mounted (not the file). This means:

- **Why a directory, not the file:** a single-file `virtiofs` bind mount is
  pinned to the file's inode. Editors save atomically (write temp + rename =
  new inode), which silently breaks a file-level mount — the mounted path
  vanishes inside the container (`No such file or directory` while `mount` still
  lists it). A directory mount is inode-stable and survives host edits.
- **Live everywhere.** On each interactive login, `entrypoint.sh`'s `.bashrc`
  hook copies `/tmp/claude-host/settings.json` → `/root/.claude/settings.json`
  (writable) and exports effort. Editing the host file takes effect on the next
  `claude` launch — no recreate, no restart, no image rebuild.
- **Host is never modified** — the mount is read-only; the container only copies
  *from* it.
- Seeded with defaults by `create.sh` on first run (`model`, `effortLevel`,
  `ANTHROPIC_DEFAULT_*_MODEL` pins).
- **`model`** (+ `theme`, pins) come from the copied `settings.json`.
  **`effortLevel`** is NOT reliably applied from `settings.json` (Claude Code
  holds effort at the model default), so it is exported as
  `CLAUDE_CODE_EFFORT_LEVEL` — the highest-precedence effort control.
- **Per-repo override:** a `.claude/settings.local.json` at the workspace repo
  root can override **`model`** (Claude Code merges settings key-by-key:
  managed > CLI flags > project `.local` > project > user). It can **not**
  override effort, since `CLAUDE_CODE_EFFORT_LEVEL` (env) outranks all
  `settings.json` tiers; use `claude --effort <level>` for a one-off.
- Interactive `/model` / `/effort` don't persist across restarts (the copy is
  refreshed from the host file each login); the host file is the durable source.
- Auth wiring is **not** in this file — it is passed as env vars (see below).

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
- **Generated**: Once by `create.sh` if absent
- **Shared**: Across all profiles
- **Security**: Dedicated keypair, never uses user's personal SSH keys

### SSH Config Entries

Auto-managed by `create.sh` and `delete.sh`.

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

- Each profile has a **base port** (defined in `profile_port()` in `create.sh`)
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
    cline)           echo 2260 ;;
    *)               echo 2299 ;;
  esac
}
```

## Environment Variables Passed to Container

`create.sh` sets these env vars for container use:

```bash
WORKSPACE_PATH=/Users/you/path/to/workspace
CONTAINER_NAME=claude-importantproject
CLAUDE_AUTH_TYPE=vertex
```

These are used by `entrypoint.sh` to:
- Write MOTD with workspace info
- Configure PS1 prompt
- (Claude Code settings come from a live read-only mount, not the entrypoint — see above)

### Auth Env Vars (derived from `CLAUDE_AUTH_TYPE`)

`CLAUDE_AUTH_TYPE` is the single user-facing auth control (`vertex`/`api`/`web`,
auto-detected or forced via `FORCE_CLAUDE_AUTH`). `create.sh` translates it into
the Claude Code built-in env vars the container actually needs — these are
**not** stored in `settings.json`:

```bash
# CLAUDE_AUTH_TYPE=vertex →
CLAUDE_CODE_USE_VERTEX=1        # derived internal flag, not a user knob
ANTHROPIC_VERTEX_PROJECT_ID=... # from ~/.config/claude-code-vertex/env.sh or shell
CLOUD_ML_REGION=global

# CLAUDE_AUTH_TYPE=api →
ANTHROPIC_API_KEY=sk-ant-...
```

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

Add case to `profile_port()` in `bin/create.sh`:

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

If your tool uses Claude as a backend, add detection logic in `create.sh`:

```bash
# In create.sh, volume mount section:
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
- [x] `bin/create.sh` - Create/resume container lifecycle
- [x] `bin/delete.sh` - Permanent container removal with cleanup
- [x] State file management

### Phase 2: Auth Unification ✅
- [x] Auth auto-detection logic
- [x] Unified `claude` profile
- [x] Machine-level config file
- [x] Backward compatibility (old profiles still work)

### Phase 2b: Cline Profile ✅
- [x] `profiles/cline/` - Cline CLI + VS Code remote extension
- [x] Multi-provider config seeding (Anthropic API key + OpenAI-compat)
- [x] Host config directory mount (`~/.config/container-dev/cline/`)
- [x] Live re-seed on each login (no recreate needed for config changes)
- [x] Cline VS Code extension baked into image, auto-installed on first Remote-SSH connect

### Phase 3: Opencode Profiles 🚧
- [x] `profiles/opencode/` - Opencode with Anthropic API key auth
- [ ] `profiles/opencode-local/` - Opencode with llama.cpp
- [ ] Model download helpers
- [ ] Testing

### Phase 4: Pi Profiles 🚧
- [x] `profiles/pi/` - Pi with Anthropic API key auth
- [ ] `profiles/pi-local/` - Pi with llama.cpp

### Phase 5: Polish 🚧
- [ ] Comprehensive testing
- [ ] Migration guide for old profiles

## Troubleshooting

### Stale State File

If containers aren't auto-replacing:
```bash
cat ~/.config/container-dev/state
```

Before removing anything, confirm the container is actually gone —
`container list --all` is the source of truth, not the state file. If it's
still listed there, don't touch its state entry; `container-dev list` reconciles
automatically (and, since it checks `container list --all`'s exit status
first, won't wipe entries just because the container runtime is still
starting up, e.g. right after a reboot).

If a line really is stale, remove only that one container's line — never
truncate or blank the whole file:
```bash
cp ~/.config/container-dev/state ~/.config/container-dev/state.bak
sed -i '' '/^<exact-container-name>|/d' ~/.config/container-dev/state
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

Transient-container entries can accumulate (they're recreated under the same
`{profile}-transient` name, but a leftover entry from a differently-named
run can linger). Clean up manually:
```bash
# Back up first
cp ~/.ssh/config ~/.ssh/config.bak

# Remove only *-transient entries — safe for every profile, and can't
# touch persistent containers since their names don't end in -transient.
sed -i '' '/^Host .*-transient$/,/^$/d' ~/.ssh/config
```

Do **not** match on a bare profile prefix like `Host claude-` — persistent
containers are named `{profile}-{workspace-slug}` (e.g. `claude-books`), so a
prefix pattern deletes their entries too, silently and with no way to tell
which container it was afterward. To remove one specific persistent
container's entry, use `container-dev delete <container-name>` — it targets
the exact host block and cleans up the matching state entry at the same
time.
