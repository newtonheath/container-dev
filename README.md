# container-dev

Containerized development environments for macOS using Apple's `container` CLI. Each container is an isolated Fedora 44 environment with SSH access and your repo mounted at `/workspace`.

## Features

- **Claude Code in a container**: Isolated coding assistant with auto-detected auth (Vertex AI, API key, or browser OAuth)
- **Transient by default**: Drop-in/drop-out workspace switching with auto-cleanup
- **Persistent opt-in**: Long-lived containers for important projects
- **Multiple workspaces**: Mount several directories into a single container
- **Machine-level auth**: Configure Claude authentication once per machine
- **Simple command interface**: `container-dev create/delete/list`

## Installation

```bash
cd ~/path/to/container-dev
./install.sh
```

This creates a symlink at `~/.local/bin/container-dev`. Make sure `~/.local/bin` is in your PATH.

## Quick Start

```bash
# Create a transient container (auto-replaced when switching workspaces)
cd ~/my-project
container-dev create claude
ssh claude-transient

# Work in another project (auto-replaces the transient container)
cd ~/another-project
container-dev create claude
ssh claude-transient  # Same SSH hostname, different workspace

# Create a persistent container for an important project
cd ~/work/critical-project
container-dev create claude --persistent
ssh claude-criticalproject  # Dedicated container, never auto-replaced
```

## Profiles

| Profile | Tool | Backend | Use Case |
|---------|------|---------|----------|
| `claude` | Claude Code | Claude API | Main AI coding assistant (auth auto-detected) |

Legacy profiles (`claude-vertex`, `claude-pro-api`, `claude-pro-web`) still work but are deprecated. Use the unified `claude` profile instead.

## Container Types

### Transient (Default)

**Best for**: Quick experiments, switching between many repos

- **One per profile**: `claude-transient`
- **Auto-replaced**: When you switch workspaces, the old container is stopped and recreated
- **SSH hostname**: `ssh claude-transient`

```bash
cd ~/experiments/test-1
container-dev create claude
ssh claude-transient

cd ~/experiments/test-2
container-dev create claude  # Replaces test-1 container
ssh claude-transient         # Same hostname, new workspace
```

### Persistent (Opt-in with `--persistent`)

**Best for**: Long-lived projects you return to frequently

- **One per workspace**: `claude-importantproject`, `claude-clientwork`
- **Never auto-replaced**: Dedicated container stays until you explicitly delete it
- **SSH hostname**: `ssh claude-importantproject`

```bash
cd ~/work/important-project
container-dev create claude --persistent
ssh claude-importantproject

cd ~/work/another-project
container-dev create claude --persistent
ssh claude-anotherproject

# Both containers stay running simultaneously
container-dev list
```

## Multiple Workspaces

Mount several directories into a single container:

```bash
# Transient — works the same as single workspace
container-dev create claude ~/projects/scraps ~/projects/relval
# Mounts: /workspace/scraps, /workspace/relval
ssh claude-transient

# Persistent — requires a name (prompted if not provided)
container-dev create claude ~/projects/scraps ~/projects/relval --persistent --name my-stack
ssh claude-my-stack
```

Each directory is mounted under `/workspace/<dirname>` inside the container.

For persistent containers with multiple workspaces, a name is required since there's no single directory to derive one from. Pass `--name` or you'll be prompted interactively.

## Environment Variables

Environment variables can be passed to containers at two levels:

### 1. User-Level (Global)

**Location:** `~/.config/container-dev/env`

Create this file to pass environment variables to **all containers** across all profiles.

**Option A: Reference host environment (recommended for secrets)**

List variable names only - values are read from your shell environment:

```bash
# ~/.config/container-dev/env
JIRA_TOKEN
JIRA_EMAIL
GITHUB_TOKEN
```

These variables must be set in your shell (e.g., in `~/.bashrc` or `~/.zshrc`). The container will receive their current values when started.

**Option B: Direct values**

Specify values directly in the file:

```bash
# ~/.config/container-dev/env
GITHUB_TOKEN=ghp_your_token_here
JIRA_TOKEN=your_jira_token
EDITOR=vim
DEBUG=1
```

**You can mix both approaches:** Variables with `=` use the specified value, variables without `=` are expanded from your environment.

**Security Note:** This file stays on your machine and is never committed to git.

### 2. Profile-Level

**Location:** `profiles/<profile>/.env`

Create a `.env` file in a profile directory for variables specific to that profile:

```bash
# profiles/claude/.env
ANTHROPIC_API_KEY=sk-ant-your-key-here
EDITOR=vim
```

These are only loaded when creating that specific profile.

**Note:** Profile `.env` files can be committed to git for shared defaults, but avoid committing secrets.

### Loading Order

Variables are loaded in this order (later overrides earlier):
1. User-level env file (`~/.config/container-dev/env`)
2. Profile-level env file (`profiles/<profile>/.env`)

## Authentication (Claude-based profiles)

Authentication is **machine-level**: configure once per machine, and `container-dev` auto-detects it.

### Vertex AI (for GCP users)

```bash
# On your work laptop with gcloud
gcloud auth application-default login

# Create container (auto-detects Vertex)
container-dev create claude
```

The unified `claude` profile detects the gcloud ADC file and uses Vertex AI automatically.

### API Key (for Claude Pro users)

Set your API key in the user-level env file:
```bash
# ~/.config/container-dev/env
ANTHROPIC_API_KEY=sk-ant-your-key-here
```

Or in the profile-level env file:
```bash
# profiles/claude/.env
ANTHROPIC_API_KEY=sk-ant-your-key-here
```

`container-dev create claude` will auto-detect the API key.

### Browser OAuth (fallback)

If no gcloud ADC or API key is found, Claude Code will use browser OAuth on first launch.

**Override detection:**

Edit `~/.config/container-dev/config`:
```bash
FORCE_CLAUDE_AUTH=vertex  # or: api, web
```

## Commands

### `container-dev create <profile> [dirs...] [--persistent]`

Create a container for the current workspace, or resume a stopped one.

**Options:**
- `--persistent` / `-p` - Create dedicated container (never auto-replaced)
- `--name <slug>` - Container name suffix (prompted interactively for persistent + multiple dirs)
- `--size small|medium|large` - Resource preset (default: medium)
- `--cpus <n>` - CPU cores
- `--mem <size>` - Memory limit (e.g., `4g`)
- `--port <port>` - Host SSH port (default: auto-assigned)

**Examples:**
```bash
# Transient (default)
container-dev create claude

# Persistent
container-dev create claude --persistent

# Multiple workspaces
container-dev create claude ~/projects/scraps ~/projects/relval

# With custom resources
container-dev create claude --size large
container-dev create claude --cpus 6 --mem 8g
```

### `container-dev delete <container-name>`

Permanently remove a container and clean up its SSH config and state. Warns before deleting persistent containers.

```bash
container-dev delete claude-transient
container-dev delete claude-importantproject
```

### `container-dev list`

Show all containers (running and stopped) with their type, workspace, and SSH hostname. Automatically cleans up stale entries for containers removed outside of `container-dev`.

```bash
$ container-dev list

Container-dev Environments
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Transient Containers (auto-replaced on workspace change)
───────────────────────────────────────────────────────────────────
  ssh claude-transient  [running]
  code --remote ssh-remote+claude-transient /workspace
    Profile:   claude
    Workspace: /Users/you/experiments/test
    Port:      2222

Persistent Containers (dedicated, never auto-replaced)
───────────────────────────────────────────────────────────────────
  ssh claude-bigproject  [running]
  code --remote ssh-remote+claude-bigproject /workspace
    Profile:   claude
    Workspace: /Users/you/work/bigproject
    Port:      2223
```

### Pause and Resume

Use the native Apple `container` CLI directly:

```bash
# Pause (frees memory, preserves filesystem)
container stop claude-transient

# Resume
container start claude-transient
```

`container-dev create` also resumes a stopped container if the workspace matches.

## Workspace Naming

For persistent containers, the workspace directory name becomes part of the SSH hostname:

```bash
cd ~/work/important-project
container-dev create claude --persistent
# Creates: claude-importantproject
# SSH: ssh claude-importantproject
```

With multiple workspaces, use `--name` to choose the name explicitly:

```bash
container-dev create claude ~/svc ~/fleet --persistent --name my-stack
# Creates: claude-my-stack
# SSH: ssh claude-my-stack
```

**Tip:** Use clear, descriptive directory names for workspaces you plan to make persistent.

## VS Code Integration

```bash
# Create container
cd ~/my-project
container-dev create claude --persistent

# Connect VS Code
code --remote ssh-remote+claude-myproject /workspace

# Or use VS Code's "Remote-SSH: Connect to Host" command
# and select "claude-myproject" from the list
```

**Safety:** Persistent containers stay connected even when you're working elsewhere. Forgotten VS Code windows can't accidentally reconnect to the wrong workspace.

## Migration from Old Profiles

If you were using `claude-vertex`, `claude-pro-api`, or `claude-pro-web`:

1. Use the unified `claude` profile instead
2. Auth is auto-detected (or override in `~/.config/container-dev/config`)
3. Old profiles still work (deprecated) but will eventually be removed

```bash
# Old way (deprecated)
container-dev create claude-vertex

# New way
container-dev create claude
```

## Troubleshooting

### "Command not found: container-dev"

Add `~/.local/bin` to your PATH:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Wrong Claude auth method detected

Override in `~/.config/container-dev/config`:
```bash
FORCE_CLAUDE_AUTH=api
```

### Port already in use

`container-dev` auto-assigns the next available port. Check with:
```bash
container-dev list
```

### Transient container not auto-replacing

Check the state file:
```bash
cat ~/.config/container-dev/state
```

If stale, delete the container:
```bash
container-dev delete claude-transient
```

## Architecture

- **Runtime**: Apple `container` CLI (not Docker/Podman)
- **Base image**: Fedora 44
- **SSH**: Dedicated ed25519 keypair at `~/.config/container-dev/keys/`
- **State tracking**: `~/.config/container-dev/state`
- **Config**: `~/.config/container-dev/config`

See [CLAUDE.md](CLAUDE.md) for implementation details.

## Adding New Profiles

See [CLAUDE.md](CLAUDE.md) for instructions on adding new profiles.
