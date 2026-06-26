# container-dev

Containerized AI development environments for macOS. Run Claude Code (or other AI agents) inside isolated Fedora containers while editing code in VS Code on the host via Remote-SSH.

## How It Works

```
┌─── Host (macOS) ──────────────┐      ┌─── Container (Fedora 44) ────┐
│                               │      │                              │
│  VS Code ──── SSH ────────────┼─────►│  Claude Code (AI agent)      │
│                               │      │  gcloud CLI                  │
│  ~/repos/my-project ──────────┼─────►│  /workspace (bind mount)     │
│                               │      │                              │
│  ~/.config/gcloud/ADC ────────┼─────►│  Vertex AI auth (read-only)  │
│                               │      │                              │
└───────────────────────────────┘      └──────────────────────────────┘
```

- The container handles all AI agent interactions — not the host
- Code lives on the host and is bind-mounted into the container
- SSH keypair is auto-generated (your personal keys are never used)
- Resource limits (CPU, memory) are set per launch

## Prerequisites

- macOS with Apple's `container` CLI (`container --version`)
- VS Code with the [Remote - SSH](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-ssh) extension
- For Vertex AI: `gcloud` CLI installed and authenticated (`gcloud auth application-default login`)

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

Each profile is a directory under `profiles/` containing a `Dockerfile`, SSH and entrypoint configs, and an `env.example` template.

### claude-vertex (Google Cloud Vertex AI)

Uses Claude Code via Vertex AI. Authentication works by mounting your host's gcloud Application Default Credentials (read-only) into the container.

**Setup:**
1. Authenticate on the host: `gcloud auth application-default login`
2. Copy and edit the env file:
   ```bash
   cp profiles/claude-vertex/env.example profiles/claude-vertex/.env
   ```
3. Fill in your GCP project ID and region in `.env`

**Per-profile SSH port:** 2222

### claude-pro (Claude Pro / API Key)

Uses Claude Code with an Anthropic API key. No gcloud or Vertex AI dependencies — just your API key.

**Setup:**
1. Copy and edit the env file:
   ```bash
   cp profiles/claude-pro/env.example profiles/claude-pro/.env
   ```
2. Add your Anthropic API key to `.env`

**Per-profile SSH port:** 2223

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
       claude-pro)     echo 2223 ;;
       my-profile)     echo 2224 ;;
       *)              echo 2225 ;;
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
│   ├── claude-vertex/
│   └── claude-pro/
│       ├── Dockerfile
│       ├── sshd_config
│       ├── entrypoint.sh
│       ├── env.example       # Committed template
│       └── .env              # Your actual config (gitignored)
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
