# container-dev

Containerized development environments for macOS using Apple's `container` CLI. Each container is an isolated Fedora 44 environment with SSH access and your repo mounted at `/workspace/<repo-name>`.

## Features

- **Claude Code in a container**: Isolated coding assistant with auto-detected auth (Vertex AI, API key, or browser OAuth)
- **OpenAI Codex in a container**: Codex CLI + VS Code extension with persistent ChatGPT/API authentication state
- **Cline in a container**: Cline CLI + VS Code extension, no Node.js on your host — supports Anthropic API or any LAN OpenAI-compatible server
- **Transient by default**: Drop-in/drop-out workspace switching with auto-cleanup
- **Persistent opt-in**: Long-lived containers for important projects
- **Multiple workspaces**: Mount several directories into a single container
- **Machine-level auth**: Configure authentication once per machine, auto-detected on create
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

| Profile | Tool | Backend | Port | Use Case |
|---------|------|---------|------|----------|
| `claude` | Claude Code | Claude API | 2222 | Main AI coding assistant (auth auto-detected) |
| `codex` | OpenAI Codex CLI | OpenAI | 2270 | Codex CLI + VS Code extension (ChatGPT or API-key auth) |
| `cline` | Cline | Anthropic API or LAN OpenAI-compat server | 2260 | Cline CLI + VS Code extension (no Node on host) |
| `opencode` | [OpenCode](https://opencode.ai) | Anthropic API key by default; Vertex via `--config work-vertex` | 2230 | Portable, provider-agnostic slash commands |
| `pi` | [Pi](https://pi.dev) | Anthropic API | 2240 | Lightweight Anthropic-API-only assistant |

Full profile registry (ports, auth, network policy, named configs) lives in
[`config/container-dev.yaml`](config/container-dev.yaml) — see
[CLAUDE.md](CLAUDE.md) for the schema.

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

Each directory is mounted as `/workspace/<dirname>` inside the container (same as single-workspace containers).

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

**Set your Vertex project and region.** `container-dev` reads these from
`~/.config/claude-code-vertex/env.sh` (if present) when creating a container, so
your project is defined in one place and never committed to this repo:

```bash
# ~/.config/claude-code-vertex/env.sh
export CLAUDE_CODE_USE_VERTEX=1
export CLOUD_ML_REGION=global
export ANTHROPIC_VERTEX_PROJECT_ID=itpc-ca-YOUR-PROJECT-ID-HERE
```

If this file is absent, `container-dev` falls back to `ANTHROPIC_VERTEX_PROJECT_ID`
and `CLOUD_ML_REGION` from your shell environment (region defaults to `global`).

> **Model access is governed by your project's org policy**
> (`constraints/vertexai.allowedModels`). If a model isn't on the allowlist you
> get a `400 FAILED_PRECONDITION ... disallowed Gen AI model` error — this is a
> policy/model or wrong-project problem, **not** an auth failure. The models the
> container requests are defined in the host-level settings file
> `~/.config/container-dev/claude/settings.json` (`model`, `effortLevel`, and the
> `ANTHROPIC_DEFAULT_OPUS_MODEL` etc. pins); update those to models your project
> allows. **No image rebuild or recreate is needed** — edit the file and it
> applies live on the next `claude` launch in any container. See
> [Model & effort configuration](#model--effort-configuration) below.

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

Copy `config/config.example.yaml` to `~/.config/container-dev/config.yaml` and set:
```yaml
auth:
  force: vertex   # or: api, web
```
This is re-evaluated on every `create`/`list`/`delete` run — no sticky cache.

### Model & effort configuration

The default model and reasoning effort live in a host-level settings file that
you can edit freely — **no image rebuild, no container recreate required**:

```bash
# ~/.config/container-dev/claude/settings.json
{
  "theme": "dark",
  "model": "sonnet",          # alias (opus/sonnet/haiku) or full model id
  "effortLevel": "high",      # low | medium | high | xhigh
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5@20251001"
  }
}
```

This file is created with sane defaults the first time you run
`container-dev create`. Its **parent directory** is bind-mounted read-only at
`/tmp/claude-host` inside every Claude-based container, and each interactive
login refreshes a writable copy into `/root/.claude/settings.json` and exports
effort from it.

- **Live everywhere.** Edit the file on the host and it takes effect the next
  time you launch `claude` in *any* container — just `ssh` back in and run it.
  No recreate, no restart.
- **Edit-safe.** We mount the *directory*, not the file. A single-file bind
  mount is pinned to the file's inode, so saving in an editor (which writes a
  new inode) would silently break it; a directory mount survives edits.
- **Host is never modified** by a container (the mount is read-only; the
  container only ever copies *from* it).
- **`model`** (and `theme`, the model-alias pins) come from the copied
  `settings.json`.
- **`effortLevel`** is applied a different way: Claude Code holds effort at the
  model default and won't reliably apply `effortLevel` from `settings.json`. So
  the login shell exports it as `CLAUDE_CODE_EFFORT_LEVEL` (the highest-
  precedence effort control), sourced live from the mounted file. You still just
  set `effortLevel` here — it works live all the same.
- Auth wiring is separate and automatic — passed as environment variables based
  on `CLAUDE_AUTH_TYPE`, not stored in this file.

#### Per-repo overrides

To override the host defaults for a single project, add a
`.claude/settings.local.json` at the repo root in your workspace. Claude Code
**merges settings key-by-key** at higher precedence, so you only specify what
you want to change:

```jsonc
// <repo>/.claude/settings.local.json   (add to the repo's .gitignore)
{ "model": "opus" }
```

With the above, that repo uses `opus` while `theme` and the model pins still
come from the host file. Remove the key (or the file) and the host default
applies again — the override wins "only when set."

> **Effort caveat:** per-repo `effortLevel` in `settings.local.json` does **not**
> take effect, because effort is applied via the `CLAUDE_CODE_EFFORT_LEVEL`
> environment variable, which outranks every `settings.json` tier. To change
> effort for a single run, use `claude --effort <level>`.

> **Note:** because the container's `settings.json` is refreshed from the host
> file on each login, the *interactive* `/model` and `/effort` commands won't
> persist across `claude` restarts. The host-file defaults above are the
> durable way to set model/effort; for a one-off change use
> `.claude/settings.local.json` or the `claude --model <m> --effort <level>`
> launch flags.

## Codex Profile

The `codex` profile installs the OpenAI Codex CLI and the `openai.chatgpt` VS Code
extension inside the container:

```bash
container-dev create codex
ssh codex-transient
codex
```

The host's Codex state directory is mounted read-write at `/root/.codex`. It uses
`$CODEX_HOME` when set, otherwise `~/.codex`, so file-backed login state, config,
sessions, and the local Codex cache survive transient container replacement.

### ChatGPT account authentication

For a portable login, configure Codex to store credentials in its file-backed
state and log in on the host (if Codex is installed there):

```toml
# ~/.codex/config.toml
cli_auth_credentials_store = "file"
```

```bash
codex login
container-dev create codex
```

Alternatively, connect to the container and complete the device login there:

```bash
ssh codex-transient
codex login --device-auth
```

The container cannot read a macOS keychain entry directly. If the host login is
stored only in the keychain, use the file-backed setting above or log in inside
the container.

### OpenAI API key authentication

Put `OPENAI_API_KEY` (or `CODEX_ACCESS_TOKEN` for trusted automation) in
`~/.config/container-dev/env` as a variable name or `KEY=value`. The entrypoint
uses it to bootstrap Codex login when no cached `auth.json` exists. API-key
usage is billed through the OpenAI API rather than a ChatGPT subscription.

Codex configuration is read from `~/.codex/config.toml`. Useful settings include
`model`, `model_reasoning_effort`, and `sandbox_mode`; the container boundary
means the normal Codex sandbox can be configured there according to your needs.

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
  code --remote ssh-remote+claude-transient /workspace/test
    Workspace: /Users/you/experiments/test
    Profile:   claude
    Port:      2222

Persistent Containers (dedicated, never auto-replaced)
───────────────────────────────────────────────────────────────────
  ssh claude-bigproject  [running]
  code --remote ssh-remote+claude-bigproject /workspace/bigproject
    Workspace: /Users/you/work/bigproject
    Profile:   claude
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

# Connect VS Code (path shown in create output)
code --remote ssh-remote+claude-myproject /workspace/my-project

# Or use VS Code's "Remote-SSH: Connect to Host" command
# and select "claude-myproject" from the list
```

For multi-workspace containers, open one folder first, then use "Add Folder to Workspace" in VS Code to add additional repos:

```bash
# Create with multiple workspaces
container-dev create claude ~/svc ~/fleet --persistent --name my-stack

# Open the first repo
code --remote ssh-remote+claude-my-stack /workspace/svc

# Then in VS Code: File > Add Folder to Workspace > /workspace/fleet
```

**Note:** The first VS Code server download (~186MB) can take a few minutes on slow connections. Subsequent connects are instant.

**Codex extension:** baked into the `codex` image and auto-installed into the
VS Code Server on the first Remote-SSH connection. Use the generated host name,
for example:

```bash
container-dev create codex --persistent
code --remote ssh-remote+codex-myproject /workspace/my-project
```

If the image was built before Codex support was added, remove `codex-img` so the
next `container-dev create codex` rebuilds it.

**Claude Code extension:** baked into the `claude` image and auto-installed into the VS
Code Server the moment it appears on first Remote-SSH connect — no manual "Install in
SSH: ..." click needed, and it works on transient containers too (which get destroyed
and recreated on every workspace switch, unlike persistent ones). If you built your
`claude-img` before this was added, delete the image (`container image rm claude-img`)
so the next `container-dev create claude` rebuilds it.

**Safety:** Persistent containers stay connected even when you're working elsewhere. Forgotten VS Code windows can't accidentally reconnect to the wrong workspace.

## Cline Profile

The `cline` profile installs [Cline](https://cline.bot) inside a container — no Node.js on your host machine required. It supports two providers:

- **Anthropic API** — requires a direct `sk-ant-...` key from [console.anthropic.com](https://console.anthropic.com) (Vertex AI is not supported by Cline)
- **LAN OpenAI-compatible server** — point at a local llama.cpp, Ollama, or similar server

The Cline CLI and VS Code remote extension (`saoudrizwan.claude-dev`) share the same config inside the container, so configuring one configures both.

### Prerequisites

**For Anthropic API key:** ensure `ANTHROPIC_API_KEY` is set in your environment or `~/.config/container-dev/env`. Note: Cline requires a direct Anthropic API key — Vertex AI credentials cannot be used here.

**For a LAN model server:**
- The server must listen on `0.0.0.0` (not just `127.0.0.1`). For llama.cpp: `llama-server --host 0.0.0.0 --port 8080 --model your-model.gguf`
- You need the server's **IP address** — `.local` mDNS hostnames do not resolve inside containers. Find it on your Mac:
  ```bash
  dns-sd -G v4 yourserver.local
  ```

### Setup

Create the host config directory and files **before** creating the container. Use `--config <name>` to keep configs for different providers separate:

```bash
# --- Anthropic API key ---
mkdir -p ~/.config/container-dev/cline/anthropic
echo "anthropic" > ~/.config/container-dev/cline/anthropic/provider
# ANTHROPIC_API_KEY must be in ~/.config/container-dev/env or your shell environment

container-dev create cline --config anthropic --persistent
# → container named cline-anthropic-<workspace>

# --- LAN model server ---
mkdir -p ~/.config/container-dev/cline/mini4
echo "mini4" > ~/.config/container-dev/cline/mini4/provider   # any name you like
cat > ~/.config/container-dev/cline/mini4/openai.json <<'EOF'
{
  "baseUrl": "http://192.168.3.120:8080/v1",
  "modelId": "your-model-id",
  "contextWindow": 131072,
  "supportsImages": false
}
EOF

container-dev create cline --config mini4 --persistent
# → container named cline-mini4-<workspace>
```

> **Use the IP address, not the hostname.** `.local` mDNS does not resolve inside the container. Get the IP with `dns-sd -G v4 yourserver.local` and put that in `baseUrl`.

> **`contextWindow`** tells Cline the model's actual context limit. Without it, Cline falls back to a conservative default (~8k) and will truncate long conversations. Set it to the value your server reports.

Then create the container:

```bash
# Without --config (flat layout, container named cline-transient)
container-dev create cline
ssh cline-transient

# With --config <name> (named layout, container includes the config name)
container-dev create cline --config mini4      # → cline-mini4-transient
container-dev create cline --config anthropic  # → cline-anthropic-transient

cline "say hello"
```

Using `--config` is recommended when you want multiple Cline containers running simultaneously (e.g. one for Anthropic, one for your LAN model) — `container-dev list` will show `cline-anthropic-transient` and `cline-mini4-transient` as distinct entries.

### Config seeding

On each SSH login, `~/.cline/data/globalState.json` and `secrets.json` are automatically refreshed from your host config files. This means:

- **Edit `openai.json` or `provider` on your Mac → re-login → change takes effect.** No container recreate needed.
- If you created the container before the config files were in place, re-login is enough to pick them up.
- If something looks wrong, you can force a reseed manually: `_seed_cline_config`

### Switching providers

The `provider` file sets the **default** active provider at login. Both providers are pre-configured in the container, so the VS Code extension's provider picker lets you switch mid-session without re-logging in. A re-login resets to whatever the `provider` file says.

```bash
# Switch default to LAN server (flat layout)
echo "mini4" > ~/.config/container-dev/cline/provider
ssh cline-transient   # reseeds on login

# Switch back to Anthropic
echo "anthropic" > ~/.config/container-dev/cline/provider
ssh cline-transient
```

For running both providers simultaneously, use named configs instead of switching:

```bash
# ~/.config/container-dev/cline/anthropic/provider → "anthropic"
# ~/.config/container-dev/cline/mini4/provider     → "mini4"

container-dev create cline --config anthropic --persistent
container-dev create cline --config mini4     --persistent
# Both run at once on different ports; container-dev list shows both clearly
```

### VS Code integration

```bash
container-dev create cline --persistent
code --remote ssh-remote+cline-myproject /workspace/my-project
```

The Cline extension (`saoudrizwan.claude-dev`) installs automatically in the remote VS Code Server when you attach. It reads from the same `~/.cline/data/` directory as the CLI, so no separate auth setup is needed.

> **"gpt-4o" label in the UI** — Cline displays "gpt-4o" as the model name for OpenAI-compatible providers regardless of which model is actually loaded. The `$0.00` cost confirms no cloud API is being called; inference is happening on your local server.

### Troubleshooting: Cline

**`error: Cannot connect to API`**

1. Verify the server IP is reachable from the container:
   ```bash
   curl -s http://192.168.3.120:8080/v1/models | jq '.data[0].id'
   ```
   If this hangs or fails, check that the server is listening on `0.0.0.0` and that you're using the IP address, not a `.local` hostname.

2. Check the seeded config looks right:
   ```bash
   cat ~/.cline/data/globalState.json | jq '{apiProvider, openAiBaseUrl}'
   ```
   If the values are wrong or null, run `_seed_cline_config` to force a reseed.

**Config shows `anthropic` but you want the LAN model**

The container was likely created before the `provider` file was set. Re-login is enough:
```bash
echo "mini4" > ~/.config/container-dev/cline/provider
ssh cline-transient  # reseeds on login
```

**`cline auth` as a fallback**

If automatic seeding fails for any reason, `cline auth` → "Bring your own provider" lets you configure interactively. What it writes to `~/.cline/data/` is identical to what the seeding produces, so it's safe to use and won't interfere with future reseeds.

**Deprecation warnings on every response**

```
DeprecationWarning: AI SDK Warning (openai-compatible.chat / gpt-4o): ...
```

These are internal noise from Cline's bundled AI SDK and are harmless. They cannot be suppressed via environment variables. They will disappear when Cline updates its dependency.

## Troubleshooting

### "Command not found: container-dev"

Add `~/.local/bin` to your PATH:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

### Wrong Claude auth method detected

Override in `~/.config/container-dev/config.yaml`:
```yaml
auth:
  force: api
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
- **Config**: `config/container-dev.yaml` (repo defaults) deep-merged with
  `~/.config/container-dev/config.yaml` (machine overrides, optional)

See [CLAUDE.md](CLAUDE.md) for implementation details.

## Adding New Profiles

See [CLAUDE.md](CLAUDE.md) for instructions on adding new profiles.
