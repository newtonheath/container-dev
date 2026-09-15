# Plan: `codex` Profile (OpenAI Codex CLI)

Status: **draft**

`opencode --config work-openai` is on ice. This plan supersedes it with a clean
`codex` profile that mirrors the `claude` profile architecture.

## Context

The `claude` profile is the template:
- `FROM container-dev-base` (Fedora 44 + common tooling + SSH)
- Tool installed via npm at build time
- VS Code extension `.vsix` baked into the image; background watcher in
  `entrypoint.sh` installs it once VS Code Server appears (no manual step)
- Credentials forwarded as env vars via `~/.config/container-dev/env` +
  explicit `-e` flags in `create.sh`
- Tool config seeded at first SSH login (not at build time)

Codex CLI is `@openai/codex` (npm). Its VS Code extension is **`openai.chatgpt`**
on Open VSX (display name: "Codex – OpenAI's coding agent"), available as a single
`.vsix` — not arch-split like Claude Code's, same shape as Cline's. Download key
in the Open VSX JSON response is `files.download`.

Node is already present on Fedora 44 via the base image.

## Goal

```bash
container-dev create codex              # transient, current dir
container-dev create codex --persistent # persistent
ssh codex-transient
```

Container boots with:
- `codex` CLI on PATH
- `OPENAI_API_KEY` visible in interactive SSH sessions
- `~/.codex/config.toml` seeded with model, sandbox policy, and reasoning effort
- VS Code sidebar panel (`openai.chatgpt`) auto-installed on first Remote-SSH
  connect, without any manual "Install in SSH" step

## Credentials and configuration

**`OPENAI_API_KEY`**: add as a bare name in `~/.config/container-dev/env` — the
existing `load_env_file` mechanism already forwards it. `create.sh` also passes it
explicitly via `-e` with a warning if unset.

**Model and reasoning effort**: codex reads `~/.codex/config.toml`, not env vars.
`entrypoint.sh` seeds this file on first login (guarded by `[[ ! -f ]]`, same
pattern as opencode). Two optional passthrough env vars drive the seed:

| Env var | Config.toml key | Default if unset |
|---|---|---|
| `CODEX_MODEL` | `model` | omitted (codex uses its own default) |
| `CODEX_REASONING_EFFORT` | `reasoning_effort` | omitted |

**Sandbox**: in a container the container itself is the sandbox boundary. Seed
`sandbox_permissions = ["disk-full-read-access", "disk-full-write-access"]` in
config.toml so codex doesn't re-prompt for every file operation. This is the
`danger-full-access` equivalent from the CLI flag, expressed in config form.

## Required Changes

### 1. `profiles/codex/` — new profile directory

**`Dockerfile`**:
```dockerfile
FROM container-dev-base:latest

RUN npm install -g @openai/codex

# VS Code extension — single .vsix (not arch-split, same shape as Cline)
RUN mkdir -p /opt/vsix && \
    VSIX_URL=$(curl -fsSL https://open-vsx.org/api/openai/chatgpt | \
      python3 -c "import json,sys; print(json.load(sys.stdin)['files']['download'])") && \
    curl -fsSL -o /opt/vsix/codex.vsix "$VSIX_URL"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

CMD ["/usr/local/bin/entrypoint.sh"]
```

**`entrypoint.sh`**:
- SSH key copy (standard)
- MOTD: profile=codex, tool=Codex CLI, backend=OpenAI API
- PS1 + `cd /workspace`
- `.container_env` dump — captures `OPENAI_API_KEY`, `CODEX_MODEL`,
  `CODEX_REASONING_EFFORT`, and everything else from the env files
- Config seeding (first-login guard `[[ ! -f ~/.codex/config.toml ]]`):
  ```toml
  # seeded by container-dev entrypoint.sh
  sandbox_permissions = ["disk-full-read-access", "disk-full-write-access"]
  ```
  If `CODEX_MODEL` is set, append `model = "<value>"`.
  If `CODEX_REASONING_EFFORT` is set, append `reasoning_effort = "<value>"`.
  Use string concatenation into the file — no jq/yq needed for TOML this simple.
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
- Add a codex env block:
  ```bash
  if [[ "$PROFILE" == "codex" ]]; then
    if [[ -z "${OPENAI_API_KEY:-}" ]]; then
      echo "WARN: OPENAI_API_KEY is not set — add it to ~/.config/container-dev/env" >&2
    fi
    CONTAINER_ENV+=(-e "OPENAI_API_KEY=${OPENAI_API_KEY:-}")
    [[ -n "${CODEX_MODEL:-}" ]]            && CONTAINER_ENV+=(-e "CODEX_MODEL=$CODEX_MODEL")
    [[ -n "${CODEX_REASONING_EFFORT:-}" ]] && CONTAINER_ENV+=(-e "CODEX_REASONING_EFFORT=$CODEX_REASONING_EFFORT")
  fi
  ```
- Add `codex` to the auth-display summary block at container launch:
  `"   Auth:      OpenAI API key"` (skip the `CLAUDE_AUTH_TYPE` path).
- No auth-detection logic — codex is API-key only.

### 4. `CLAUDE.md` — document the new profile

- Add `codex` row to the Profiles table (tool: Codex CLI, backend: OpenAI API,
  auth: `OPENAI_API_KEY`, port: 2270).
- Add short note on optional `CODEX_MODEL` / `CODEX_REASONING_EFFORT` env vars.

## Verification

- `bash -n` on all modified scripts.
- `git diff --check`.
- `container build` completes for `codex-img` (npm install + vsix download).
- `container-dev create codex` boots and SSH connects as `ssh codex-transient`.
- `echo $OPENAI_API_KEY` inside container returns the key.
- `codex --version` works.
- `~/.codex/config.toml` exists with `sandbox_permissions` set after first login.
- VS Code Remote-SSH installs `openai.chatgpt` sidebar extension without manual steps.
- End-to-end: run a `codex` prompt inside the container.

## Out of scope

- `opencode --config work-openai` (deferred).
- Named `--config` variants for codex (single-provider for now).
- Network policy enforcement (declared via `openai-standard`, not yet enforced).
- `codex-local` / llama.cpp backend.
