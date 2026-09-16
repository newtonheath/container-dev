# Plan: `codex` Profile (OpenAI Codex CLI)

Status: **implemented**

`opencode --config work-openai` is on ice. This plan supersedes it with a clean
`codex` profile that mirrors the `claude` profile architecture.

## Context

The `claude` profile is the template:
- `FROM container-dev-base` (Fedora 44 + common tooling + SSH)
- Tool installed with the official standalone Codex installer at build time
- VS Code extension `.vsix` baked into the image; background watcher in
  `entrypoint.sh` installs it once VS Code Server appears (no manual step)
- Codex's `CODEX_HOME` mounted from the host, preserving file-backed login state,
  config, sessions, and cache across container replacement
- Optional `OPENAI_API_KEY` or `CODEX_ACCESS_TOKEN` bootstrap via
  `~/.config/container-dev/env`

Codex's VS Code extension is **`openai.chatgpt`** on Open VSX and is staged as an
architecture-matched `.vsix` in the image. Node is already present on Fedora 44,
but the CLI uses the standalone installer rather than relying on npm package
naming.

## Goal

```bash
container-dev create codex              # transient, current dir
container-dev create codex --persistent # persistent
ssh codex-transient
```

Container boots with:
- `codex` CLI on PATH
- Host `CODEX_HOME` available at `/root/.codex`
- ChatGPT login state available when stored in file-backed `auth.json`
- `OPENAI_API_KEY` or `CODEX_ACCESS_TOKEN` available when configured
- VS Code sidebar panel (`openai.chatgpt`) auto-installed on first Remote-SSH
  connect, without any manual "Install in SSH" step

## Credentials and configuration

**ChatGPT account login**: Codex CLI and its IDE extension share cached login
details. Configure `cli_auth_credentials_store = "file"` in the host's
`~/.codex/config.toml` before running `codex login`, or run
`codex login --device-auth` after connecting to the container. A macOS keychain
entry is not directly readable from the Linux container.

**`OPENAI_API_KEY`**: add as a bare name or `OPENAI_API_KEY=value` in
`~/.config/container-dev/env`. The existing env-file mechanism forwards it, and
the entrypoint uses it to create a Codex login when no cached `auth.json` exists.
API-key usage is billed through the OpenAI API rather than a ChatGPT subscription.

**Configuration**: Codex reads `~/.codex/config.toml`. Current settings such as
`model`, `model_reasoning_effort`, and `sandbox_mode` are deliberately owned by
the mounted host config rather than being overwritten by the container entrypoint.

## Required Changes

### 1. `profiles/codex/` — implemented profile directory

**`Dockerfile`**:
```dockerfile
FROM container-dev-base:latest

RUN curl -fsSL https://chatgpt.com/codex/install.sh | \
      CODEX_HOME=/opt/codex-installer-home \
      CODEX_INSTALL_DIR=/usr/local/bin \
      CODEX_NON_INTERACTIVE=1 sh

# VS Code extension — choose the native Linux architecture from Open VSX
RUN mkdir -p /opt/vsix && \
    ARCH="$(uname -m)" && \
    case "$ARCH" in \
      x86_64)  VSIX_PLATFORM=linux-x64 ;; \
      aarch64) VSIX_PLATFORM=linux-arm64 ;; \
      *) exit 1 ;; \
    esac && \
    VSIX_URL=$(curl -fsSL https://open-vsx.org/api/openai/chatgpt/latest | \
      python3 -c "import json,sys; print(json.load(sys.stdin)['downloads']['$VSIX_PLATFORM'])") && \
    curl -fsSL -o /opt/vsix/codex.vsix "$VSIX_URL"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
```

**`entrypoint.sh`**:
- SSH key copy (standard)
- MOTD: profile=codex, tool=Codex CLI, and resolved auth state
- PS1 + `cd /workspace`
- `.container_env` dump — captures the configured environment for SSH sessions
- Auth bootstrap from a mounted `auth.json`, `CODEX_ACCESS_TOKEN`, or
  `OPENAI_API_KEY`; otherwise the MOTD explains how to use device auth
- Background VS Code extension watcher (mirrors claude's pattern exactly):
  polls for `code-server`, installs `/opt/vsix/codex.vsix` once, checks
  extension ID `openai.chatgpt`
- `exec /usr/sbin/sshd -D`

No settings-file/effort mount needed — codex does not have a host-settings
directory equivalent to claude's `~/.config/container-dev/claude/`.

### 2. `config/container-dev.yaml` — register the profile

```yaml
profiles:
  codex:
    port: 2270
    backend: openai
    network: openai-standard
```

`backend: openai` is a new value. `cfg_profile_backend` reads it generically —
no lib/config.sh changes needed.

### 3. `bin/create.sh`

- Add `codex` to the profile list in `usage()` and the examples.
- Add a writable `$CODEX_HOME:/root/.codex` mount and pass `CODEX_HOME`,
  `CODEX_AUTH_TYPE`, `OPENAI_API_KEY`, and `CODEX_ACCESS_TOKEN` as applicable.
- Resolve cached auth after env files are loaded, so secrets can remain in the
  existing host env file without being sourced into the host shell.

### 4. `CLAUDE.md` — document the new profile

- Add `codex` row to the Profiles table (tool: Codex CLI, backend: OpenAI API,
  auth: file-backed ChatGPT login or `OPENAI_API_KEY`, port: 2270).
- Add notes on ChatGPT file-backed login, device auth, API-key bootstrap, and
  the `CODEX_HOME` mount.

## Verification

- `bash -n` on all modified scripts.
- `git diff --check`.
- `container build` completes for `codex-img` (standalone installer + native VSIX download).
- `container-dev create codex` boots and SSH connects as `ssh codex-transient`.
- `echo $OPENAI_API_KEY` inside container returns the key.
- `codex --version` works.
- `~/.codex/auth.json` is reused when file-backed ChatGPT auth is configured.
- VS Code Remote-SSH installs `openai.chatgpt` sidebar extension without manual steps.
- End-to-end: run a `codex` prompt inside the container.

## Out of scope

- `opencode --config work-openai` (deferred).
- Named `--config` variants for codex (single-provider for now).
- Network policy enforcement (declared via `openai-standard`, not yet enforced).
- `codex-local` / llama.cpp backend.
