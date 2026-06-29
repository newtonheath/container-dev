# container-dev

Containerized Claude Code environments for macOS. Each profile is an isolated Fedora 44 container accessible via SSH, with the user's repo bind-mounted at `/workspace`.

## Runtime

Uses Apple's `container` CLI (not Docker or Podman). Commands are `container build`, `container run`, `container list`, `container stop`, `container image list`, etc. This matters when reading `start.sh` and `stop.sh`.

## Key files

- `bin/start.sh` — builds image if needed, runs container, writes `~/.ssh/config` entry
- `bin/stop.sh` — stops and removes a named container
- `profiles/<name>/Dockerfile` — Fedora 44 base, openssh-server, Claude Code via npm
- `profiles/<name>/entrypoint.sh` — copies SSH pubkey into place, writes `/root/.claude/settings.json`, execs sshd
- `profiles/<name>/sshd_config` — hardened SSH config (pubkey only, no password, no PAM)

## Profiles and auth methods

| Profile | Auth | SSH port |
|---|---|---|
| `claude-vertex` | gcloud ADC mounted read-only from host | 2222 |
| `claude-pro-api` | `ANTHROPIC_API_KEY` via `.env` | 2223 |
| `claude-pro-web` | Browser OAuth — token persisted on host | 2224 |
| catch-all | — | 2225 |

Port map lives in `profile_port()` in `bin/start.sh`. Update it whenever adding a profile.

## Volume mounts (per launch)

| Source (host) | Destination (container) | Who sets it up |
|---|---|---|
| `<workspace>` | `/workspace` | always, `start.sh` |
| `~/.config/container-dev/keys/container_ed25519.pub` | `/tmp/pubkey/authorized_keys` (ro) | always, `start.sh` |
| `~/.config/gcloud/application_default_credentials.json` | `/root/.config/gcloud/...` (ro) | vertex only, `start.sh` |
| `~/.config/container-dev/auth/claude-pro-web/` | `/root/.claude/` | web only, `start.sh` |

## SSH keypair

A single ed25519 keypair at `~/.config/container-dev/keys/container_ed25519` is shared across all profiles. Generated once by `start.sh` if absent. Never uses the user's personal SSH keys. `~/.ssh/config` entries are auto-appended on first start using the `${PROFILE}-host` naming pattern. Keys live in `~/.config` (not the repo) so SSH config entries remain valid regardless of where the repo is placed in the filesystem.

## .env handling

`.env` is **optional**. `start.sh` passes `--env-file` only when the file exists. Profiles that don't need env vars (e.g. `claude-pro-web`) require no `.env` at all. Profiles that do (`claude-pro-api`, `claude-vertex`) have an `env.example` template.

## Browser OAuth token persistence (claude-pro-web)

`/root/.claude/` in the container is bind-mounted from `~/.config/container-dev/auth/claude-pro-web/` on the host. `entrypoint.sh` overwrites `settings.json` on each start, but the OAuth credential file (written by Claude Code after browser auth) is a separate file and persists across container delete/recreate. Token expiry is set by Anthropic, not container lifecycle.

## Naming conventions

For a profile named `foo`:
- Image: `foo-img`
- Container: `foo-container`
- SSH host alias: `foo-host`

## Adding a new profile

1. Create `profiles/<name>/` with `Dockerfile`, `entrypoint.sh`, `sshd_config`
2. Add a port case to `profile_port()` in `bin/start.sh` (shift the catch-all up)
3. If the profile needs env vars, add `env.example`
4. If the profile uses browser OAuth, add an `AUTH_MOUNT_ARGS` case in `start.sh` mirroring the `claude-pro-web` block
