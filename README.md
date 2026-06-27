# container-dev

Containerized AI development environments for macOS. Run Claude Code (or other AI agents) inside isolated Fedora containers while editing code in VS Code on the host via Remote-SSH.

## How It Works

```
┌─── Host (macOS) ──────────────┐      ┌─── Container (Fedora 44) ────┐
│                               │      │                              │
│  VS Code / SSH ───────────────┼─────►│  Claude Code (TUI or IDE)    │
│                               │      │                              │
│  ~/repos/my-project ──────────┼─────►│  /workspace (bind mount)     │
│                               │      │                              │
│  Profile (.env, auth) ────────┼─────►│  Auth + config (per profile) │
│                               │      │                              │
└───────────────────────────────┘      └──────────────────────────────┘
```

- **Profiles** define how the container authenticates (Vertex AI, API key, or browser OAuth) — each has its own Dockerfile, env config, and SSH port
- Code lives on the host and is bind-mounted into the container
- SSH keypair is auto-generated (your personal keys are never used)
- Resource limits (CPU, memory) are set per launch

## Prerequisites

- macOS with Apple's `container` CLI (`container --version`)
- VS Code with the [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension
- For `claude-vertex`: `gcloud` CLI installed and authenticated (`gcloud auth application-default login`)
- For `claude-pro-api`: an Anthropic API key

## Quick Start

```bash
# 1. Create your env file from the template
cp profiles/claude-vertex/env.example profiles/claude-vertex/.env
# Edit .env with your GCP project ID and region

# 2. Launch a container pointing at your repo
./bin/start.sh claude-vertex ~/repos/my-project

# 3. Connect
ssh claude-vertex-host
# Or from VS Code: Remote-SSH → connect to "claude-vertex-host"

# 4. Stop when done
./bin/stop.sh claude-vertex
```

## Usage

```
./bin/start.sh <profile> <workspace> [options]
```

| Argument    | Description                              |
|-------------|------------------------------------------|
| `profile`   | Profile name (directory under `profiles/`) |
| `workspace` | Host directory to mount as `/workspace`  |

| Option                        | Description                    |
|-------------------------------|--------------------------------|
| `--size small\|medium\|large` | Resource preset (default: medium) |
| `--cpus <n>`                  | CPU cores (overrides --size)   |
| `--mem <size>`                | Memory limit, e.g. 8g (overrides --size) |
| `--port <port>`               | Host SSH port (overrides per-profile default) |

### Size Presets

| Preset | CPUs | Memory | Use case                        |
|--------|------|--------|---------------------------------|
| small  | 2    | 2g     | Light editing, small repos      |
| medium | 4    | 4g     | Default — typical dev work      |
| large  | 6    | 8g     | Heavy agent workloads           |

### Examples

```bash
# Default (medium) resources
./bin/start.sh claude-vertex ~/repos/my-project

# Large preset for heavy workloads
./bin/start.sh claude-vertex ~/repos/my-project --size large

# Custom resources
./bin/start.sh claude-vertex ~/repos/my-project --cpus 6 --mem 8g
```

## Profiles

Three profiles are available, each using a different authentication method:

| Profile | Auth method | SSH port |
|---|---|---|
| `claude-vertex` | Google Cloud Vertex AI (gcloud ADC) | 2222 |
| `claude-pro-api` | Anthropic API key | 2223 |
| `claude-pro-web` | Browser OAuth (Claude.ai subscription) | 2224 |

### claude-vertex (Google Cloud Vertex AI)

Authenticates via gcloud Application Default Credentials mounted read-only from the host — no API key required.

**Setup:**
1. Authenticate on the host: `gcloud auth application-default login`
2. Copy and edit the env file:
   ```bash
   cp profiles/claude-vertex/env.example profiles/claude-vertex/.env
   ```
3. Fill in your GCP project ID and region in `.env`

### claude-pro-api (Anthropic API key)

Authenticates using an Anthropic API key injected via `.env`. No browser login or gcloud required.

**Setup:**
1. Copy and edit the env file:
   ```bash
   cp profiles/claude-pro-api/env.example profiles/claude-pro-api/.env
   ```
2. Add your `ANTHROPIC_API_KEY` to `.env`

### claude-pro-web (Browser OAuth)

Authenticates via Claude.ai browser login — no API key needed. You authenticate once interactively; the OAuth token is stored in `.auth/claude-pro-web/` on the host and mounted back into the container on every subsequent start, so you are not prompted again until the token expires.

**Setup:** none — no `.env` file required.

**First run:**
```bash
./bin/start.sh claude-pro-web ~/repos/my-project
ssh claude-pro-web-host
claude   # prompts for browser auth on first use only
```

**Token persistence:** the credential file lives at `.auth/claude-pro-web/` on the host (gitignored). Deleting and recreating the container does not invalidate it — only token expiry (set by Anthropic) will require re-authentication.

### Naming Convention

For a profile named `claude-vertex`:

| Resource       | Name                    |
|----------------|-------------------------|
| Image          | `claude-vertex-img`       |
| Container      | `claude-vertex-container` |
| SSH host       | `claude-vertex-host`      |

## Connecting VS Code

The `start.sh` script automatically adds an SSH host entry to `~/.ssh/config`, so VS Code can connect with no manual configuration.

1. **Open VS Code** on your Mac
2. Open the Command Palette (`Cmd+Shift+P`)
3. Type **"Remote-SSH: Connect to Host..."** and select it
4. Choose **`claude-vertex-host`** (or `<profile>-host` for other profiles) from the list
5. VS Code will open a new window connected to the container
6. Open the `/workspace` folder — this is your bind-mounted repo

Once connected, the VS Code terminal runs inside the container. Run `claude` there to start the AI agent — it will use Vertex AI automatically with no setup prompts.

To open directly from the command line:
```bash
code --remote ssh-remote+claude-vertex-host /workspace
```

## Creating a New Profile

To add support for a different AI tool or auth method:

1. Create a new directory under `profiles/`:
   ```
   profiles/my-profile/
   ├── Dockerfile       # Base image, tools, SSH server setup
   ├── sshd_config      # Can copy from an existing profile
   ├── entrypoint.sh    # Copies SSH key into place, starts sshd
   └── env.example      # Template for required env vars
   ```

2. The Dockerfile should:
   - Install `openssh-server` and your AI tool
   - Run `ssh-keygen -A` to generate SSH host keys
   - Run `passwd -d root` to unlock the root account for SSH
   - Copy `sshd_config` and `entrypoint.sh` into the image
   - End with `CMD ["/usr/local/bin/entrypoint.sh"]`

3. Add a port mapping in `bin/start.sh` in the `profile_port()` function:
   ```bash
   profile_port() {
     case "$1" in
       claude-vertex)  echo 2222 ;;
       claude-pro-api) echo 2223 ;;
       claude-pro-web) echo 2224 ;;
       my-profile)     echo 2225 ;;
       *)              echo 2226 ;;
     esac
   }
   ```

4. Create your `.env` from the template and launch:
   ```bash
   cp profiles/my-profile/env.example profiles/my-profile/.env
   ./bin/start.sh my-profile ~/repos/my-project
   ```

## Project Structure

```
container-dev/
├── bin/
│   ├── start.sh              # Build and launch a container
│   └── stop.sh               # Stop and remove a container
├── profiles/
│   ├── claude-vertex/        # Vertex AI auth (gcloud ADC)
│   ├── claude-pro-api/       # API key auth
│   │   ├── Dockerfile
│   │   ├── sshd_config
│   │   ├── entrypoint.sh
│   │   ├── env.example       # Committed template
│   │   └── .env              # Your actual config (gitignored)
│   └── claude-pro-web/       # Browser OAuth auth
│       ├── Dockerfile
│       ├── sshd_config
│       └── entrypoint.sh     # No .env needed
├── .auth/                    # Persisted browser OAuth tokens (gitignored)
│   └── claude-pro-web/       # Mounted as /root/.claude in container
├── .keys/                    # Auto-generated SSH keypair (gitignored)
└── .gitignore
```

## Managing Images and Containers

```bash
# List running containers
container list

# List built images
container image list

# Stop a specific profile's container
./bin/stop.sh claude-vertex

# Stop all dev containers
./bin/stop.sh

# Remove an image (forces rebuild on next start)
container image rm claude-vertex-img:latest
```
