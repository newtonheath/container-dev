# container-dev

Containerized development environments for macOS using Apple's `container` CLI. Each container is an isolated Fedora 44 environment with SSH access and your repo mounted at `/workspace`.

## Features

- **Multiple AI coding tools**: Claude Code, Opencode, Pi (with Claude or local llama.cpp backends)
- **Transient by default**: Drop-in/drop-out workspace switching with auto-cleanup
- **Persistent opt-in**: Long-lived containers for important projects
- **Machine-level auth**: Configure Claude authentication once per machine
- **Simple command interface**: `container-dev start/stop/list/persist`

## Installation

```bash
cd ~/path/to/container-dev
./install.sh
```

This creates a symlink at `~/.local/bin/container-dev`. Make sure `~/.local/bin` is in your PATH.

## Quick Start

```bash
# Start a transient container (auto-replaced when switching workspaces)
cd ~/my-project
container-dev start claude
ssh claude-transient

# Work in another project (auto-replaces the transient container)
cd ~/another-project
container-dev start claude
ssh claude-transient  # Same SSH hostname, different workspace

# Create a persistent container for an important project
cd ~/work/critical-project
container-dev start claude --persistent
ssh claude-criticalproject  # Dedicated container, never auto-replaced
```

## Profiles

| Profile | Tool | Backend | Use Case |
|---------|------|---------|----------|
| `claude` | Claude Code | Claude API | Main AI coding assistant (auth auto-detected) |
| `opencode` | Opencode | Claude API | Alternative tool with Claude backend |
| `opencode-local` | Opencode | llama.cpp | Offline/privacy-focused with local model |
| `pi` | Pi | Claude API | Pi coding assistant with Claude |
| `pi-local` | Pi | llama.cpp | Pi with local model |

## Container Types

### Transient (Default)

**Best for**: Quick experiments, switching between many repos

- **One per profile**: `claude-transient`, `opencode-transient`
- **Auto-replaced**: When you switch workspaces, the old container is stopped and recreated
- **SSH hostname**: `ssh claude-transient`

```bash
cd ~/experiments/test-1
container-dev start claude
ssh claude-transient

cd ~/experiments/test-2
container-dev start claude  # Replaces test-1 container
ssh claude-transient        # Same hostname, new workspace
```

### Persistent (Opt-in with `--persistent`)

**Best for**: Long-lived projects you return to frequently

- **One per workspace**: `claude-importantproject`, `claude-clientwork`
- **Never auto-replaced**: Dedicated container stays running until you explicitly stop it
- **SSH hostname**: `ssh claude-importantproject`

```bash
cd ~/work/important-project
container-dev start claude --persistent
ssh claude-importantproject

cd ~/work/another-project
container-dev start claude --persistent
ssh claude-anotherproject

# Both containers stay running simultaneously
container-dev list
```

## Environment Variables

Environment variables can be passed to containers at three levels:

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
OPENAI_API_KEY
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

These are only loaded when starting that specific profile.

**Note:** Profile `.env` files can be committed to git for shared defaults, but avoid committing secrets.

### 3. One-Time Override

Pass environment variables for a single container start:

```bash
# Set a variable just for this container
SPECIAL_TOKEN=secret123 container-dev start claude --persistent

# Multiple variables
DEBUG=1 LOG_LEVEL=verbose container-dev start opencode
```

### Loading Order

Variables are loaded in this order (later overrides earlier):
1. User-level env file (`~/.config/container-dev/env`)
2. Profile-level env file (`profiles/<profile>/.env`)
3. One-time overrides (command-line)

## Authentication (Claude-based profiles)

Authentication is **machine-level**: configure once per machine, and `container-dev` auto-detects it.

### Vertex AI (for GCP users)

```bash
# On your work laptop with gcloud
gcloud auth application-default login

# Start container (auto-detects Vertex)
container-dev start claude
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

`container-dev start claude` will auto-detect the API key.

### Browser OAuth (fallback)

If no gcloud ADC or API key is found, Claude Code will use browser OAuth on first launch.

**Override detection:**

Edit `~/.config/container-dev/config`:
```bash
FORCE_CLAUDE_AUTH=vertex  # or: api, web
```

## Commands

### `container-dev start <profile> [--persistent]`

Start a container for the current workspace.

**Options:**
- `--persistent` / `-p` - Create dedicated container (never auto-replaced)
- `--size small|medium|large` - Resource preset (default: medium)
- `--cpus <n>` - CPU cores
- `--mem <size>` - Memory limit (e.g., `4g`)

**Examples:**
```bash
# Transient (default)
container-dev start claude

# Persistent
container-dev start claude --persistent

# With custom resources
container-dev start opencode-local --size large
container-dev start pi --cpus 6 --mem 8g
```

### `container-dev stop <container-name>`

Stop and remove a container. Warns before stopping persistent containers.

```bash
container-dev stop claude-transient
container-dev stop claude-importantproject
```

### `container-dev list`

Show all running containers with their type (transient vs persistent), workspace, and SSH hostname.

```bash
$ container-dev list

📦 Transient Containers (auto-replaced on workspace change)
───────────────────────────────────────────────────────────
  ssh claude-transient
    Profile:   claude
    Workspace: /Users/you/experiments/test
    Port:      2222

🔒 Persistent Containers (dedicated, never auto-replaced)
───────────────────────────────────────────────────────────
  ssh claude-bigproject
    Profile:   claude
    Workspace: /Users/you/work/bigproject
    Port:      2223

  ssh opencode-local-research
    Profile:   opencode-local
    Workspace: /Users/you/research/ml
    Port:      2231
```

### `container-dev persist`

Convert the current workspace's transient container to persistent.

```bash
cd ~/work/project
container-dev start claude        # Transient
# ...work for a while, decide to keep it...
container-dev persist             # Now persistent
```

**Note:** Full implementation pending - currently guides manual recreation.

## Local Models (for `*-local` profiles)

Profiles ending in `-local` (e.g., `opencode-local`, `pi-local`) use llama.cpp for inference.

### Model Storage

Models are stored in `~/.config/container-dev/models/` and shared across all local profiles.

### Download a Model

```bash
mkdir -p ~/.config/container-dev/models
cd ~/.config/container-dev/models

# Example: CodeLlama 7B (4.8 GB)
wget https://huggingface.co/TheBloke/CodeLlama-7B-GGUF/resolve/main/codellama-7b.Q4_K_M.gguf

# Example: DeepSeek Coder 6.7B (4.1 GB)
wget https://huggingface.co/TheBloke/deepseek-coder-6.7b-instruct-GGUF/resolve/main/deepseek-coder-6.7b-instruct.Q4_K_M.gguf
```

### Configure Model

Create `profiles/opencode-local/.env`:
```bash
LLAMA_MODEL_PATH=/root/.cache/models/codellama-7b.Q4_K_M.gguf
LLAMA_CONTEXT_SIZE=8192
LLAMA_THREADS=4
```

## Workspace Naming

For persistent containers, the workspace directory name becomes part of the SSH hostname:

```bash
cd ~/work/important-project
container-dev start claude --persistent
# Creates: claude-importantproject
# SSH: ssh claude-importantproject
```

**Tip:** Use clear, descriptive directory names for workspaces you plan to make persistent.

## VS Code Integration

```bash
# Start container
cd ~/my-project
container-dev start claude --persistent

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
# Old way
./bin/start.sh claude-pro-api ~/my-project

# New way
cd ~/my-project
container-dev start claude
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

If stale, manually stop the container:
```bash
container-dev stop claude-transient
```

## Architecture

- **Runtime**: Apple `container` CLI (not Docker/Podman)
- **Base image**: Fedora 44
- **SSH**: Dedicated ed25519 keypair at `~/.config/container-dev/keys/`
- **State tracking**: `~/.config/container-dev/state`
- **Config**: `~/.config/container-dev/config`

See [CLAUDE.md](CLAUDE.md) for implementation details.

## Adding New Profiles

See [CLAUDE.md](CLAUDE.md) for instructions on adding Opencode and Pi profiles.
